# asuswrt-merlin-fleetctl — plan

Agnostic AiMesh fleet orchestration for Asuswrt-Merlin: run commands, push
files, and roll out any addon across a mesh over SSH — from the main router
itself or from a workstation.
Extracted from flowcache-doctor's fleet-mode design (its issue #6 archives the
original field data); follows the `asuswrt-merlin-accessctl` pattern —
general capability, own repo, addon-independent.

Born from a field request by SNBForums user jksmurf (flowcache-doctor thread
97561, post-998532): one-off install across the mesh, no per-node SSH toil.

Requirements from the first consumer are in `CONSUMER-BRIEF.md`. Contributor
constraints and design invariants are in `AGENTS.md`. This file tracks **what
is built, what is verified, and what is still open**.

## Why standalone

- Nothing in it is addon-specific: discovery, trust model, eligibility gate,
  SSH fan-out, merged output — generic plumbing any addon can use.
- Nothing like it exists: amtm is single-router; node-touching addons
  (e.g. Wireless Report) each hand-roll their own node SSH.
- Security-sensitive machinery (SSH orchestration) lives in ONE auditable
  place instead of being copied into every addon.
- flowcache-doctor is the first consumer: its mesh rollout docs reduce to
  "install fleetctl, then `fleetctl install <doctor-install-url>`".

## Trust model (the load-bearing design decision)

**The user prepares the trust; fleetctl only consumes it.** fleetctl NEVER
writes `sshd_authkeys` or any security-relevant nvram.

One-time user setup:

1. The user needs a key that reaches the router. `fleetctl keygen` will make
   one (file creation only, in fleetctl's own path — NOT `/jffs/.ssh/`, which
   holds firmware-managed sshd host keys) and **print** the pubkey with paste
   instructions — but it is optional and **never run automatically**: point
   `FLEET_KEY` at an existing key, or on a workstation let `~/.ssh` do it.
   See *0.2 decisions* below on the credentials boundary.
2. The user pastes the pubkey into the router GUI's SSH authorized-keys
   field (Administration → System). **AiMesh syncs that field byte-for-byte
   to every node** (verified live 2026-07-22 on RT-BE92U + RP-BE58:
   `sshd_authkeys` nvram identical on both, node materializes it at
   `/root/.ssh/authorized_keys`, `cfg_client` daemon carries it). Current
   AND future nodes inherit the trust automatically — zero per-node steps.
3. The user lists the nodes in `fleetctl.conf` (`fleetctl discover` suggests
   them, pinned and conf-ready).

Side effect worth documenting: the router's key ends up authorized on the
router itself. Harmless; lets fleet code treat "local unit" and "remote
node" uniformly if ever useful.

### Password login (supported reluctantly, discouraged loudly)

Key auth is the design. Password auth exists only as an explicit opt-in
escape hatch (`FLEET_ALLOW_PASSWORD=1`, or `auth=pass` per node) for "I just
want to try it" cases. **Verified 2026-07-28: `DROPBEAR_PASSWORD` IS compiled
into Merlin's dbclient** (v2026.91 on 3006.102.8), so the fallback works — it
stays discouraged on trust grounds, not capability grounds. Prompted once per
scope, never echoed, **never stored**; no password lands in conf, script, or
JFFS. Refuses to prompt when there is no TTY (a cron fan-out must fail, not
hang).

## Architecture

Single busybox-sh script + conf, mirroring the doctor's conventions:

- `/jffs/scripts/fleetctl` — the tool (workstation: `~/.local/bin/fleetctl`,
  config under `~/.config/fleetctl/`)
- `/jffs/scripts/fleetctl.conf` — user config (created by installer with
  commented defaults; never overwritten)
- `/jffs/scripts/fleetctl.key` (+ `.pub`) — the client keypair
- `/jffs/scripts/fleetctl.d/.ssh/known_hosts` — fleetctl's own TOFU store
- Installed via curl one-liner from `main`; self-update via the doctor's
  proven `update` pattern (download to /tmp, exec — never overwrite a
  running script; `?cb=$(date +%s)` cache-bust; raw CDN lags pushes ~5 min)

### Node specs (revised 2026-07-28)

The original single-field `FLEET_NODES` list did not survive contact with the
real question: *how is each node actually reachable?* A node may be an IP or a
hostname, on port 22 or a custom port, authenticated by key or password, with
one shared credential or one per node. `FLEET_NODES` therefore holds **specs**:

```
[user@]host[:port][,key=value]...
fields: port=  user=  key=<identity file>  auth=pass|key  mac=<pin>  name=<label>
```

One list, not a list plus a side table — a fan-out tool with two sources of
truth for "who is in the fleet" is a foot-gun. Everything omitted inherits the
conf defaults (`FLEET_USER`, `FLEET_PORT`, `FLEET_KEY`).

Explicit `FLEET_NODES` (not live discovery) remains the runtime source of
truth: discovery output drifts (node offline, re-IP), and a tool that opens
root shells must aim at a stable, user-owned target list. Discovery is a
suggestion generator that emits **pinned** specs, so the safe path is the
default one.

### Verbs (all built)

| Verb | Action | Writes? |
|---|---|---|
| `discover` | parse `cfg_device_list` nvram → candidate nodes; test SSH auth + Merlin eligibility per node; print conf-ready pinned specs | no |
| `keygen` | create a keypair (if absent), print pubkey + GUI paste instructions. Optional, never auto-run | key files only |
| `nodes` | list configured nodes with reachability/auth/pin/eligibility status | no |
| `run <cmd>` | execute on every node, output prefixed `[node]` | whatever cmd does |
| `push <file> <dest>` | `cat`-stream fan-out, atomic temp+mv | remote file |
| `install <url> [args]` | download + run a standard addon installer on every **eligible** node; args pass through, so `install <url> uninstall` is fleet rollback | remote install |
| `health` | self-check (key, conf, client, per-node auth/pin/eligibility) | no |
| `update` | self-update | /tmp + exec |
| `uninstall` | remove fleetctl from this router | removes own files |

Global flags (before the verb): `--dry-run`, `--nodes`, `--include-self`,
`--allow-unpinned`, `--porcelain`.

### Fan-out safety (from `CONSUMER-BRIEF.md` §3 — all implemented)

Per-node OK/FAIL/SKIPPED summary + non-zero exit on any failure; wall-clock
timeouts on every remote call (own watchdog — **there is no `timeout` applet**);
continue-on-error; MAC-pin + ASUS-identity verification before anything
mutating; controller excluded from fan-out by default; no prompting without a
TTY; `--dry-run`; single-instance `mkdir` lock; serial with per-node buffering;
installer stdout surfaced per node (the placebo problem — an addon can exit 0
and still be inert).

### Eligibility gate

`install`/`push` require per node, checked live, skip-with-stated-reason on
failure:

- Merlin firmware with custom scripts: `nvram get jffs2_scripts` = 1
  (verified signature: stock RP-BE58 returns empty → correctly ineligible)
- `/jffs/scripts` exists
- SSH auth works

`run` only requires SSH — a stock node is a valid `run` target (useful in
itself: stock nodes still answer `nvram get`, `wl`, etc.).

## Verified facts

Dev mesh: RT-BE92U 3006.102.8 controller + stock RP-BE58 node.

**2026-07-22**

- Discovery: `nvram get cfg_device_list` → `<host>ip>mac>role` entries,
  `<`-separated; role `0` = node, `1` = controller (lists itself).
  `cfg_clientlist` was empty — wrong var, at least on 3006.
- Stock AiMesh nodes run dropbear on :22 (SSH enablement propagates from
  controller) — reachable, key-authenticable.
- `sshd_authkeys` sync: byte-identical router↔node; a workstation key added
  via router GUI authenticated against the node with zero node-side setup.
- Router toolbox: `dropbearkey`, `dbclient`, `scp`, `ssh` all present;
  `sshd_pass=1` (password fallback exists → GUI-paste flow is lockout-safe);
  SSH LAN-only (`sshd_enable=2`).
- Admin username syncs mesh-wide → `FLEET_USER` default works.

**2026-07-28** (read-only probe, resolving transport unknowns)

- **No `timeout` applet.** Consequence: the per-node cap is fleetctl's own
  watchdog (background child + background sleeper + marker file). This was the
  single most load-bearing finding — the whole timeout design depended on it.
- `flock` **is** present at `/usr/bin/flock`, but the lock uses `mkdir`
  anyway: portable, applet-free, and correct on builds that lack flock.
- dbclient is **Dropbear v2026.91**, and `ssh` is the same binary
  (`ssh -V` → `Dropbear`), so OpenSSH flag assumptions would have been wrong.
- dbclient supports `-p <port>`, `-i`, `-y`, **`-K <keepalive>`** and
  **`-M <max_duration>`** — used as a backstop above our own watchdog, and only
  when `dbclient -h` advertises them (an unknown flag makes dbclient exit
  before connecting).
- Its host syntax is `[user@]host/port`, **not** `host:port` — `-p` is used to
  avoid the ambiguity entirely.
- **`DROPBEAR_PASSWORD` is compiled in** (string present in the binary), so the
  password escape hatch is viable.
- Identity nvram available for pinning: `productid`, `lan_hwaddr`, `label_mac`.

**2026-07-28** (end-to-end validation of discovery + the gates, against the
live controller and node — read-only)

- The shipped discovery parser was run against the real `cfg_device_list` and
  extracted the node while correctly dropping the controller. **The controller
  is not necessarily the first record** — order carries no meaning, only
  `role`.
- **Key auth to the node works**: the GUI-pasted key authenticated straight
  into the stock RP-BE58 with zero node-side setup, confirming the one-paste
  trust model end to end (2026-07-22 verified the nvram sync; this verifies an
  actual login).
- The probe returns `model=RP-BE58 jffs= dir=no` from the stock node — i.e.
  **the eligibility gate's skip path is proven on real hardware**, not just in
  mocks.
- **The MAC pin mechanism is proven**: the MAC that `cfg_device_list` reports
  for the node IS present in that node's own MAC set (`lan_hwaddr` /
  `label_mac` / `et0macaddr`). This is why `_pin_matches` tests membership in a
  SET rather than comparing one nvram var — it does not need to know which MAC
  AiMesh chose as the node's identity. Had this not matched, `install`/`push`
  would have refused every node in the field.

## Decisions taken (previously open)

- **known-hosts policy** → TOFU in fleetctl's own store. `-y` accepts an
  *unknown* key and records it; a *changed* key stays fatal (never `-y -y`).
  `$HOME` is repointed at `/jffs/scripts/fleetctl.d` so the store is
  fleetctl's, not root's, and survives reboots (a few hundred bytes, written
  once per node — within the flash-wear rule). `FLEET_STRICT_HOSTKEY=1` opts
  into refusing unknown keys too.
- **`scp` vs `cat | ssh`** → `cat`, with an atomic temp+`mv`. It needs only
  `cat` on the far side (no scp/sftp binary, no dropbear scp quirks), and an
  interrupted push cannot leave a half-written file in place of a working one.
- **Command name** → keep `fleetctl`; the repo is published as
  `asuswrt-merlin-fleetctl`, and the on-router collision risk is nil.
- **PATH discoverability** → the installer appends one guarded line to
  `/jffs/configs/profile.add` (removed on uninstall). Same fix should land in
  flowcache-doctor (its issue #3) so the ergonomics match.

## Open questions

Ordered by how much they affect real users.

1. **How does a user enable JFFS custom scripts on an AiMesh *node*?** The
   gating precondition for installing any addon on a node, and a node has no
   web UI of its own. Does `jffs2_scripts` sync from the controller the way
   `sshd_authkeys` does, or must it be set per node over SSH? Field testers
   have addons running on their nodes, so a path exists. **Until this is
   answered, `install` is less useful than it looks** — the README says so
   plainly rather than guessing.
2. **Does a node's `/jffs` survive AiMesh re-onboarding / re-sync?** If
   re-adding a node silently wipes the addon, "installed" is not a durable
   state and `nodes` should be able to detect the drift.
3. **cfg-sync latency for a GUI-pasted key** — live, or on reboot/re-sync?
   The one-paste ergonomics depend on it. Testable at home; needs a write, so
   it is an operator step.
4. **`cfg_device_list` format on 3004-firmware controllers.** Parsed
   defensively already (unrecognised → print raw + fall back to manual
   `FLEET_NODES`), but unverified.
5. **The `install` happy path on a Merlin node.** Everything else is provable
   at home; this needs a Merlin node (jksmurf's AX3000 is the standing
   candidate).
6. **amtm packaging** — worth deciding before wide announcement.

## Testability

Everything except the `install` happy path is provable at home against the
stock RP-BE58 — which IS the ineligible-node test case. Offline, 101 black-box
tests (`sh scripts/fleetctl.test.sh`, also under `dash`) mock the router side
and cover spec parsing, the pin/identity/eligibility gates, self-exclusion,
continue-on-error, exit-status preservation, the timeout watchdog, dry-run, the
lock, and discovery's defensive paths. They have already caught two real bugs
(a `push` that silently wrote empty files, because a backgrounded command's
stdin is `/dev/null`; and a lock that never held).

## Constraints

See `AGENTS.md` — busybox sh only, no `command` builtin, no `timeout`, verify
every applet AND every dbclient flag, never `ps | grep` for processes, never
overwrite a running script, JFFS is flash, `cru` for cron, dev-router mutations
are operator-run.

## 0.2 decisions (2026-07-28)

Three owner questions reshaped the tool after v0.1 was pushed:

- **"Which host do we run on?"** → **both**. Platform is detected by
  `[ -d /jffs ]` + an ASUS-only nvram variable (never `which nvram` — macOS
  ships its own `/usr/sbin/nvram` and every Mac would be misread as a router).
  Off-router, config moves to `~/.config/fleetctl/`, `FLEET_USER` defaults to
  EMPTY so `~/.ssh/config` supplies user/port/key, and HOME is NOT repointed
  (doing so would hide the operator's agent and Host blocks). Discovery asks
  `FLEET_CONTROLLER` over SSH instead of reading local nvram.
- **"The config should be able to flag an item as self."** → the `self` spec
  (alias `local`) executes directly, no SSH hop, so a unit needs no key
  authorized against itself. Listing it IS the opt-in, so it is exempt from
  `--include-self` and from the `mac=` requirement (a pin defends against
  address indirection; local has no address). On a workstation it fails the
  mutating verbs through the ordinary identity gate — your laptop is not an
  ASUS unit — with no special-casing. `discover` emits `self` for the
  controller when run there, a pinned spec when run from a workstation.
- **"Should it manage keys/passwords on the system?"** → **no**, and the
  installer was violating that: it ran `setup` automatically, minting a private
  key just because you installed the tool. Removed. `setup` is renamed
  **`keygen`** (honest about what it does), is never invoked for the user, and
  writes only into fleetctl's own directory. See README, *What fleetctl does
  not touch*. fleetctl consumes credentials named in the config; provisioning
  them is outside the tool.
- **"Can the doctor depend on it?"** → yes, via the **CLI contract**, not
  vendoring (copying the fan-out code into each addon is the problem this repo
  exists to solve). Two public surfaces: `--porcelain`
  (`fleetctl<TAB>node<TAB>OK|FAIL|SKIPPED<TAB>reason`, columns never reordered)
  and library mode (`FLEETCTL_LIB=1 . fleetctl` exposing stable `fleet_*`
  functions). Prefer the CLI — it is version-tolerant and keeps the safety
  model on your side of the call.

Two more real bugs fell out of this work, both silent-success class and both
caught by the suite: a background child inherits the parent's stdout, so the
timeout watchdog held every `$( … )` capture open for its full duration (a 20 s
stall on every `discover` — visible only under `dash`); and `VAR=x func` does
not scope the assignment in POSIX sh, which would have leaked a forced platform
across the whole test run.

## Milestones

- **v0.1** (done): `discover` / `nodes` / `run` / `push` / `install` / `health`
  / `update` / `uninstall`, with the full fan-out safety model. Discovery
  parsing, node key-auth, the eligibility skip path and the MAC-pin check are
  confirmed on real hardware.
- **v0.2** (built, offline-tested — 143 tests under two shells): runs on a
  workstation as well as the router, `self` targets, `keygen` rename + the
  credentials boundary, `--porcelain` and library mode for consuming addons.
  Pending: live validation of the workstation path, then the `install` happy
  path in the field.
- **v0.2**: whatever the dev-mesh and field runs teach us — plus open
  questions 1–2, which may add a `nodes` drift check.
- **v0.3**: docs + SNBForums announcement; doctor README integration
  ("mesh rollout" section). Gated on flowcache-doctor issue #5 (fan-out
  multiplies confident false positives — see `CONSUMER-BRIEF.md` §5).
