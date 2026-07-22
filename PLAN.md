# asuswrt-merlin-fleetctl — plan

Agnostic AiMesh fleet orchestration for Asuswrt-Merlin: run commands, push
files, and roll out any addon across a mesh from the main router, over SSH.
Extracted from flowcache-doctor's fleet-mode design (its issue #6 archives the
original field data); follows the `asuswrt-merlin-accessctl` pattern —
general capability, own repo, addon-independent.

Born from a field request by SNBForums user jksmurf (flowcache-doctor thread
97561, post-998532): one-off install across the mesh, no per-node SSH toil.

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

1. `fleetctl setup` generates a dedicated client keypair on the router
   (file creation only, fleetctl's own path — NOT `/jffs/.ssh/`, which
   holds firmware-managed sshd host keys) and **prints** the pubkey with
   paste instructions.
2. The user pastes the pubkey into the router GUI's SSH authorized-keys
   field (Administration → System). **AiMesh syncs that field byte-for-byte
   to every node** (verified live 2026-07-22 on RT-BE92U + RP-BE58:
   `sshd_authkeys` nvram identical on both, node materializes it at
   `/root/.ssh/authorized_keys`, `cfg_client` daemon carries it). Current
   AND future nodes inherit the trust automatically — zero per-node steps.
3. The user lists the nodes in `fleetctl.conf` (`fleetctl discover` suggests
   them, see below).

Side effect worth documenting: the router's key ends up authorized on the
router itself. Harmless; lets fleet code treat "local unit" and "remote
node" uniformly if ever useful.

### Password login (supported reluctantly, discouraged loudly)

Key auth is the design. Password auth exists only as an explicit opt-in
escape hatch (`FLEET_ALLOW_PASSWORD=1`) for "I just want to try it" cases:

- Mechanism: dropbear's `dbclient` reads the `DROPBEAR_PASSWORD` env var
  (compile-time option — **VERIFY it's enabled in Merlin's dbclient before
  documenting**). fleetctl prompts ONCE per invocation, exports for its
  child dbclient calls, never echoes, **never stores** — no password ever
  lands in conf, script, or JFFS.
- Why it's bad and stays discouraged: the mesh admin password transits
  process environments; any conf-file storage would be a plaintext admin
  credential on flash. README frames it as "works, but set up the key —
  it's one paste."

## Architecture

Single busybox-sh script + conf, mirroring the doctor's conventions:

- `/jffs/scripts/fleetctl` — the tool
- `/jffs/scripts/fleetctl.conf` — user config (created by installer with
  commented defaults)
- Key at `/jffs/scripts/fleetctl.key` (+ `.pub`) by default
- Installed via curl one-liner from `main` (same distribution model as the
  doctor); self-update via the doctor's proven `update` pattern (download
  to /tmp, exec — never overwrite a running script; `?cb=$(date +%s)`
  cache-bust; raw CDN lags pushes ~5 min)

### Config surface

```sh
FLEET_NODES=""            # explicit, space-separated IPs/hosts — source of truth
FLEET_USER=""             # default: $(nvram get http_username) — AiMesh syncs
                          # the admin user to nodes (verified), so empty usually works
FLEET_KEY="/jffs/scripts/fleetctl.key"
FLEET_ALLOW_PASSWORD=0    # 1 = permit DROPBEAR_PASSWORD prompt fallback (discouraged)
```

Explicit `FLEET_NODES` (not live discovery) is deliberate: discovery output
can drift (node offline, re-IP), and a fan-out tool must have a stable,
user-owned target list. Discovery is a suggestion generator, never the
runtime source.

### Verbs (v0.1)

| Verb | Action | Writes? |
|---|---|---|
| `discover` | parse `cfg_device_list` nvram → candidate nodes; test SSH auth + Merlin eligibility per node; print conf-ready `FLEET_NODES` line | no |
| `setup` | generate keypair (if absent), print pubkey + GUI paste instructions | key files only |
| `nodes` | list configured nodes with reachability/auth/eligibility status | no |
| `run <cmd>` | execute on every node, output prefixed `[node-ip]` | whatever cmd does |
| `push <file> <dest>` | scp fan-out | remote file |
| `install <url>` | curl-pipe-sh a standard addon installer on every **eligible** node | remote install |
| `health` | self-check (key present, conf sane, per-node auth) — doctor's health pattern | no |
| `update` | self-update | /tmp + exec |

### Eligibility gate

`install` (and anything touching `/jffs`) requires per node, checked live,
skip-with-stated-reason on failure:

- Merlin firmware with custom scripts: `nvram get jffs2_scripts` = 1
  (verified signature: stock RP-BE58 returns empty → correctly ineligible)
- `/jffs/scripts` exists
- SSH auth works

`run`/`push` only require SSH — a stock node is a valid `run` target
(useful in itself: stock nodes still answer `nvram get`, `wl`, etc.).

## Verified facts (dev mesh: RT-BE92U 3006.102.8 controller + stock RP-BE58 node, 2026-07-22)

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

## Open questions / verify before shipping

- `DROPBEAR_PASSWORD` env support in Merlin's dbclient build (gates the
  password fallback — if absent, drop the feature, keep key-only).
- dbclient known-hosts policy: `-y` (accept new) on first contact vs
  pinning; decide and document the MITM trade-off.
- cfg-sync latency: does a key pasted into the GUI reach node
  `authorized_keys` live, or on reboot/re-sync? (Untested — needs a write;
  will be answered naturally during v0.1 testing on the dev mesh.)
- `cfg_device_list` format on 3004-firmware controllers (jksmurf's
  controller is 3006, so his mesh matches; pure-3004 meshes unverified).
- scp vs `cat | ssh 'cat >'` for push (dropbear scp quirks).
- Command name: `fleetctl` collides with the (dead) CoreOS fleetctl in
  web-search space; on-router collision unlikely. Revisit before publish.

## Testability on the dev mesh

Everything except the `install` happy path is testable at home against the
stock RP-BE58: `discover`, `setup`, key-auth hop, `run`, `push`, `nodes`,
and the eligibility gate's skip path (the RP-BE58 IS the ineligible-node
test case). The `install` happy path needs a Merlin node — field validation
(jksmurf's AX3000 is the standing candidate).

## Constraints (inherited from flowcache-doctor AGENTS.md — same platform)

busybox sh only; no `pgrep`/`pkill`; no `command` builtin (use `which`);
verify EVERY busybox applet with `which` before relying on it (mkfifo was
missing there — assume nothing); no `tail | while read` pipeline subshells
in daemons; never overwrite a running script (download to /tmp + exec);
JFFS is flash — runtime state goes to /tmp; `cru` for cron. Dev-router
mutations are run by the operator via `!`-prefixed commands, never by the
assistant.

## Milestones

- **v0.1**: `discover` / `setup` / `nodes` / `run` / `health` — fully
  provable on the dev mesh
- **v0.2**: `push` / `install` + eligibility gate — gate provable at home,
  install happy path validated in the field
- **v0.3**: `update` self-update + docs + SNBForums announcement; doctor
  README integration ("mesh rollout" section)
