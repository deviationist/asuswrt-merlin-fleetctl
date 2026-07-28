# AGENTS.md — guidance for AI coding agents working on this repo

This repo ships a shell tool that runs on **Asuswrt-Merlin routers under
busybox `sh`** and, from there, opens **root shells on other people's mesh
nodes**. The constraints are unusual and violating them produces silent,
hard-to-debug failures — or, worse, breaks someone's mesh. Read this before
editing anything.

## The one rule that matters most: a failed node must never look like success

fleetctl's entire value is that a user can trust its output. One command
touches N devices; if a node is silently skipped, silently unreachable, or
silently half-installed, the user has no way to notice. So:

- **Every node lands in the summary** as OK / FAIL / SKIPPED(reason), and
  fleetctl's exit code is non-zero if any node failed. Consumers (the doctor's
  `roamctl health` exits non-zero on any FAIL) rely on that signal surviving
  the fan-out.
- **Continue on error, never fail-fast.** Aborting mid-fan-out leaves a
  half-upgraded mesh with no record of where it stopped. A per-node problem is
  a per-node result, not a `die`. (`die` is for invocation-wide problems: no
  SSH client, no TTY for a password prompt, a bad URL.)
- **Never reduce a node to a checkmark.** `install` prints each node's
  installer output. An addon can install cleanly, exit 0, and still be inert
  (the doctor's interface auto-detection can land in an inert config and still
  print `Installed and HEALING`). Swallowing that output turns one silent
  misconfiguration into N invisible ones, all self-reporting success.

## The credentials boundary (added 0.2, at the owner's direction)

fleetctl **consumes** credentials; it never provisions them. Provisioning is
outside this tool's business, and keeping it outside is what makes the security
story auditable. So fleetctl must never:

- write `sshd_authkeys`, or any nvram variable, anywhere;
- add a public key to any `authorized_keys` file;
- store a password (the opt-in prompt is process-memory only, never disk);
- read credentials from anywhere but the config the operator wrote.

`keygen` is the sole command that creates key material. It writes only into
fleetctl's own directory, prints the public half, authorizes nothing, and is
**never invoked for the user** — not by the installer, not by another verb.
(The installer used to run it automatically; that was removed, because
installing a tool should not silently mint a private key on someone's system.)
If you are tempted to add "helpfully install the key for them", don't: that is
the one action that can lock a user out of their own mesh.

## Two platforms, one tool

fleetctl runs on the router AND on a workstation. Detection is `[ -d /jffs ]`
plus an ASUS-only nvram variable — **never `which nvram`**, because macOS ships
its own unrelated `/usr/sbin/nvram` and every Mac would be misread as a router.
`FLEETCTL_PLATFORM` forces the branch so the suite can cover both.

What differs, and must stay differing:

- **Config location**: `/jffs/scripts` vs `${XDG_CONFIG_HOME:-~/.config}/fleetctl`.
- **known_hosts**: the router gets fleetctl's own store (HOME repointed). A
  workstation must NOT have HOME repointed — that would hide the operator's
  `~/.ssh/config`, agent and keys, which is exactly what makes
  `FLEET_NODES="router"` work there with no config at all.
- **Empty `FLEET_USER` is meaningful off-router**: connect as a bare host and
  let `~/.ssh/config` decide. Do not "fix" it by defaulting to `admin`.
- **A missing key is a FAIL on the router, a note on a workstation** (OpenSSH
  may authenticate from an agent).

`self` (alias `local`) is a node spec meaning *this machine, executed directly*.
Being listed is the opt-in, so it bypasses the `--include-self` guard (which
covers the different case of a node ADDRESS resolving to the controller) and
needs no `mac=` pin (a pin defends against address indirection; there is none).
It is refused for mutating verbs when the machine is not an ASUS unit — via the
ordinary identity gate, not a special case. `install` of fleetctl's own
installer onto a local target is refused outright: that rewrites the running
script.

## Public contracts (breaking these breaks consumers)

fleetctl is meant to be **depended on, not vendored** — addons like
flowcache-doctor call it rather than copying it. Two surfaces are therefore
public:

- **`--porcelain`**: `fleetctl<TAB>node<TAB>OK|FAIL|SKIPPED<TAB>reason`, one row
  per node. Never reorder or repurpose a column; append if you must add one.
- **Library mode**: `FLEETCTL_LIB=1 . fleetctl` loads without running a verb and
  exposes `fleet_version`, `fleet_platform`, `fleet_list`, `fleet_spec`,
  `fleet_probe`, `fleet_eligible`, `fleet_gate`, `fleet_exec`. Those names are
  stable; the `_underscore` internals they wrap are not.

## Hard constraints (busybox / router — each one is an observed failure)

- **busybox `sh` only.** No bash, no arrays, no `[[`, no process substitution.
  `sh -n <file>` is the repo's only lint — plus `dash -n`, which is much closer
  to the router's ash than macOS's bash-as-`sh`.
- **Do not put a `case` statement inside `$( … )`.** bash 3.2 (macOS, where the
  lint runs) mis-parses it: `syntax error near unexpected token ';;'`. Feed the
  loop from a heredoc instead — which also keeps it in the current shell, so
  variables it sets survive. Both discovery loops are written this way.
- **A backgrounded command's stdin is `/dev/null`.** POSIX gives an
  asynchronous list `/dev/null` as stdin unless *explicitly* redirected. The
  timeout watchdog backgrounds the SSH client, so `push` piping a file into it
  silently sent nothing and wrote an **empty file over the destination**, exit
  0. That is why `_with_timeout` redirects from `$RUN_STDIN` explicitly. Do not
  "simplify" it away; there is a test.
- **A background child inherits the parent's stdout, and `$( … )` waits for
  EVERY writer to close that pipe.** The timeout watchdog backgrounds a sleeper;
  without `>/dev/null 2>&1` on it, `raw=$(_run_on …)` (how discovery reads the
  device list) blocks for the FULL timeout even after the call succeeded — a 20 s
  stall on every `discover`. Found by running the suite under dash.
- **`VAR=x some_function` does NOT scope the assignment.** POSIX leaves
  assignments preceding a *function* call set in the shell afterwards. It only
  scopes for external commands. This bit both the script (hence HOME is exported
  deliberately, not prefixed) and the test harness (hence `runp`, which prefixes
  an external command).
- **There is no `command` builtin.** `command -v foo` fails with
  `command: not found` — a false negative that reads as "foo is missing". Probe
  with `which`.
- **There is no `timeout` applet** (verified on RT-BE92U 3006.102.8). The
  per-node wall-clock cap is our own watchdog: background the child, background
  a sleeper that kills it, marker file to tell a timeout from an ordinary
  non-zero exit. Do not reintroduce a dependency on `timeout`.
- **Verify EVERY applet with `which` before relying on it**, and the same for
  **dbclient's own flags** — an unknown flag makes dbclient exit *before*
  connecting, so `-K`/`-M` are used only when `dbclient -h` advertises them.
  (`flock` does exist on 3006, but the lock uses `mkdir` anyway: it is the
  portable atomic-create primitive and needs no applet at all.)
- **Never find processes with a broad `ps | grep <string>`.** An SSH session
  whose command line mentions the path matches itself, and a kill loop then
  terminates the caller's own session — a real bug in this project family, and
  a sharper hazard here because fleetctl's whole job is spawning SSH clients
  whose command lines contain node addresses. Kills are by known pid only;
  liveness is `kill -0` (plus `/proc/<pid>/cmdline` to rule out pid reuse).
- **A running script must never have its file overwritten.** busybox `sh` reads
  scripts incrementally. `update` downloads the installer to `/tmp` and `exec`s
  it, so the process is replaced before the on-disk file is. Any future
  self-modifying path must follow the same pattern.
- **JFFS is flash.** Only the tool, the conf, the keypair and the (tiny,
  write-once-per-node) known_hosts live on `/jffs`. Every per-run artifact —
  buffered node output, the summary, the lock, the timeout marker — goes to
  `/tmp` (RAM). The audit trail is `logger` (RAM-backed syslog), not a file.
- **`raw.githubusercontent.com` lags pushes by up to ~5 minutes**, even with
  `?cb=$(date +%s)` (cb defeats the CDN edge, not raw's internal layer). Don't
  field-test `update` inside that window and conclude the push is broken —
  inspect `/tmp/fleetctl.update.sh` to see what was actually served.
- **No development-setup specifics in shipped code** — no real IPs, MACs,
  hostnames or SSIDs, not even in comments. This is sharper here than in sibling
  repos: **discovery output (`cfg_device_list`) is full of real MACs and
  hostnames.** Never paste captured discovery output into tests, fixtures, or
  docs. The suite uses `192.168.1.x` / `AA:BB:CC:DD:EE:xx` placeholders only.
- **Dev-router mutations are run by the operator** via `!`-prefixed commands.
  The assistant does read-only verification over SSH and never writes to the
  router. Plan the test loop around that.

## Design invariants (do not weaken)

- **fleetctl never writes `sshd_authkeys` or any AiMesh-synced / security-
  relevant nvram**, on the controller or on a node. `setup` creates files in
  fleetctl's own path and *prints* the pubkey; authorizing it is a human action
  in the GUI, because authorized-keys is the one setting that can lock a user
  out of their own mesh. The key path is deliberately **not** `/jffs/.ssh/`,
  which holds the firmware's sshd **host** keys.
- **fleetctl never restarts `cfg_client` / `cfg_server`.** Corrupted cfg-sync is
  unrecoverable for a non-expert user. Breaking the mesh is not an acceptable
  failure mode for a mesh tool.
- **Mutating verbs verify the target's identity first.** `FLEET_NODES` holds
  addresses; DHCP moves addresses; `install` is `curl … | sh` as root. So
  `install`/`push` require a `mac=` pin that matches the host that actually
  answered, plus proof it is an ASUS unit at all (`productid` via nvram).
  `--allow-unpinned` is the deliberate, explicit escape hatch. `run` is
  intentionally laxer — a read-only command on the wrong host is a nuisance,
  not a compromise. **`discover` emits pinned specs** so the safe path is also
  the default one.
- **The controller is excluded from fan-out** unless `--include-self`. It lists
  itself in `cfg_device_list` (role `1`), and fanning `install` onto self means
  a script rewriting itself while running.
- **Explicit `FLEET_NODES` is the runtime source of truth; discovery is only a
  suggestion generator.** A discovered list drifts (node offline, re-IP), and a
  fan-out tool must aim at a stable, user-owned target list. Discovery must also
  **degrade, never hard-fail**: firmware generations differ within one mesh
  (3004 nodes under a 3006 controller are in the field), so an unrecognised
  `cfg_device_list` prints the raw value and hands over to manual config.
- **The eligibility gate is only for `/jffs`-touching verbs.** A stock
  (non-Merlin) AiMesh node is a legitimate `run` target — it still answers
  `nvram get`, `wl`, etc. Verified signature: a stock node returns an empty
  `jffs2_scripts`, so it is correctly reported ineligible. Keep the split, and
  keep printing a **remediation**, not just a verdict.
- **Never prompt when there is no TTY.** A cron-driven fan-out would hang
  forever on a password prompt. Detect it and fail with a clear message.
- **Passwords are never stored.** Key auth is the design; `FLEET_ALLOW_PASSWORD`
  is an opt-in escape hatch, prompted once per scope, kept in process memory
  only. Anything else would put a plaintext mesh-admin credential on flash.
  (`DROPBEAR_PASSWORD` is compiled into Merlin's dbclient — verified 2026-07-28
  on 3006.102.8.)
- **Host keys are TOFU, in fleetctl's own known_hosts.** `-y` accepts an
  *unknown* key and records it; a *changed* key stays fatal (that would need
  `-y -y`, which we never pass). A changed key on a LAN node means a reflash or
  a spoof — the user decides which, so it is surfaced with both explanations.
- **Serial and deterministic.** Meshes are 2–4 units and the router is also
  routing. If parallelism is ever added, keep per-node buffering and the
  `[node]` prefix.
- **Single-instance lock** on the fan-out verbs (`run`/`push`/`install`). Two
  overlapping fan-outs writing the same node's `/jffs/scripts` is a corruption
  path.
- **Release checklist**: bump `VERSION` in `scripts/fleetctl` in the release
  commit, then tag `vX.Y.Z` + a GitHub Release. Docs-only changes get no
  release — users install from `main` via curl.

## Testing

- Syntax: `for f in install.sh uninstall.sh scripts/*; do sh -n "$f" && dash -n "$f"; done`
- Logic: `sh scripts/fleetctl.test.sh` — 143 black-box tests, no router needed.
  Also run `SH=dash sh scripts/fleetctl.test.sh`. All must pass.
  The suite mocks `nvram` / `dbclient` / `dropbearkey` / `logger` with per-host
  fixture files (`auth`, `model`, `jffs`, `dir`, `macs`, `rc`, `sleepsec`), so a
  node can be made unreachable, unauthenticated, stock, slow, or failing. Env
  seams: `FLEETCTL_CONF`, `FLEETCTL_HOME`, `FLEETCTL_LOCK`, `NVRAM_STATE`.
- **Add a test with every behaviour change.** The suite has already caught three
  real bugs (the async-stdin `push` truncation; a lock that never held; the
  watchdog holding a command-substitution pipe open for its whole duration —
  that last one only under `dash`, which is why both shells are run). Fan-out
  safety claims that are not tested are just comments.
- There is no CI and no router emulator. The router half — dbclient really
  authenticating with a dropbear-format key, AiMesh really syncing
  `sshd_authkeys`, real `cfg_device_list` values on other firmware generations —
  is validated live over SSH.
- Live deploy from a checkout (operator-run):
  `tar cf - -C scripts fleetctl | ssh <router> 'tar xf - -C /jffs/scripts && chmod 755 /jffs/scripts/fleetctl && /jffs/scripts/fleetctl health'`

## Architecture in one paragraph

`scripts/fleetctl` is a single busybox `sh` CLI. The conf's `FLEET_NODES` is a
space-separated list of **node specs** (`[user@]host[:port][,key=value]…`, with
`port= user= key= auth= mac= name=` fields), parsed by `_parse_spec` into the
`SPEC_*` variables that the transport layer reads — that is how one fleet list
covers hostnames or IPs, default or custom ports, and shared or per-node
credentials. `_run_on` wraps dbclient (OpenSSH tolerated) in `_with_timeout`, a
watchdog that exists because the firmware has no `timeout` applet. Every verb
funnels through `_probe` (one round trip returning model + `jffs2_scripts` +
`/jffs/scripts` + MAC set) and `_require_target`, which applies the self-,
identity-, pin- and eligibility gates and returns `go`/`skip`/`fail`; results
accumulate through `_result` into a summary that sets the process exit code.
`discover` parses `cfg_device_list` into pinned, conf-ready specs; `setup`
generates the keypair and prints the pubkey to paste; `install` runs an addon
installer per node with argument pass-through (so `install <url> uninstall` is
fleet rollback); `push` streams a file through `cat` + atomic `mv` rather than
scp. `install.sh`/`uninstall.sh` run on the router; `CONSUMER-BRIEF.md` is the
requirements brief from flowcache-doctor, the first consumer.
