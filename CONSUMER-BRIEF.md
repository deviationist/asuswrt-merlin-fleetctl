# Brief for the fleetctl agent — requirements from the first consumer

You are building `asuswrt-merlin-fleetctl`. This brief comes from
**flowcache-doctor**, the addon that will be fleetctl's first consumer and the
project the fleet design was extracted from. It carries platform constraints we
learned by breaking things on real hardware, plus the requirements that decide
whether fleetctl is actually usable as a rollout vehicle or just a nice fan-out
demo.

Treat everything under "Hard constraints" as non-negotiable — each one is a
real, observed failure, not theory. Treat "Open questions" as work to be done,
not assumptions to be inherited.

---

## 1. What "useful" means for the first consumer

The concrete success criterion: a user with a 3-unit AiMesh installs the doctor
across the whole mesh with one command, and can afterwards answer *"is it
actually working on every unit?"* without SSHing anywhere.

That decomposes into rollout (`install`), fleet-wide upgrade (which is the same
`install`, re-run), fleet-wide state (`run '… status'` / `'… health'`), and
rollback (`install` with an `uninstall` argument). Note that four of those five
need no addon-specific code at all — the generic `run` verb covers them. Resist
building addon-aware features; the value is in the fan-out being **trustworthy**,
not in it being clever.

## 2. Hard constraints — platform (learned the hard way on this exact hardware)

These come from flowcache-doctor's `AGENTS.md`. They apply verbatim; same
firmware, same busybox.

- **busybox `sh` only.** No bash, no arrays, no `[[`, no process substitution.
  `sh -n <file>` on every script is the only lint that exists — run it before
  every commit.
- **There is no `command` builtin.** `command -v foo` fails with
  `command: not found` — a false negative that reads as "foo is missing". Probe
  with `which foo` or the `type` builtin. This bit the doctor's health check.
- **The applet set is trimmed — verify EVERY applet with `which` before relying
  on it.** `mkfifo` was missing (fallback: `mkfifo || mknod <path> p`).
  `pgrep`/`pkill` are absent. Assume nothing.
- **Never find your own processes with a broad `ps | grep <string>`.** An SSH
  session whose command line mentions the path will match itself, and a kill
  loop then terminates the caller's SSH session mid-operation. This was a real
  bug in the doctor. **It is a much sharper hazard for you**, since fleetctl's
  entire job is spawning SSH clients whose command lines contain node addresses
  and remote command strings.
- **A running script must never have its file overwritten.** busybox `sh` reads
  scripts incrementally; rewriting an executing file is undefined behavior. The
  doctor's proven pattern for `update`: download to `/tmp`, then `exec` it, so
  the process is replaced before the on-disk file is. Copy this pattern exactly.
- **JFFS is flash — mind the wear.** Only config and keys belong on `/jffs`.
  Runtime state, logs, per-run scratch → `/tmp` (RAM). This matters for
  known-hosts and any audit trail you add.
- **`raw.githubusercontent.com` lags pushes by up to ~5 minutes**, even with a
  `?cb=$(date +%s)` cache-bust (cb defeats the CDN edge, not raw's internal
  layer). Don't field-test a self-update inside that window and conclude the
  push is broken — inspect what was actually served in `/tmp`.
- **No development-setup specifics in shipped code** — no real IPs, MACs,
  hostnames or SSIDs, not even in comments. Use `AA:BB:CC:DD:EE:FF` /
  `192.168.1.x` placeholders. This is sharper for you than for the doctor:
  **discovery output (`cfg_device_list`) is full of real MACs and hostnames**.
  Never commit captured discovery output into tests, fixtures, or docs
  unredacted.
- **Dev-router mutations are run by the operator**, via `!`-prefixed commands —
  the assistant does not SSH-write to the router. Read-only verification over
  SSH is fine. Plan your test loop around this.

## 3. Hard requirements — fan-out safety (the new risk class)

The doctor acts on one device. fleetctl acts on N devices with one command, and
`install` means *curl-pipe-sh as root on each of them*. That changes what
"correct" means.

1. **A failed node must never look like a successful run.** Preserve per-node
   exit status, print an explicit per-node OK/FAIL/SKIPPED(reason) summary at
   the end, and make fleetctl's own exit code non-zero if any node failed. The
   doctor's `roamctl health` deliberately exits non-zero on any FAIL — that
   signal is worthless if fleetctl swallows it.
2. **Timeouts on everything.** A node mid-reboot accepts TCP and then hangs;
   without a connect timeout *and* a wall-clock cap on the remote command, one
   sick node stalls the whole fan-out indefinitely. Verify what dropbear's
   `dbclient` actually supports here — don't assume OpenSSH flags.
3. **Continue-on-error, never fail-fast.** Aborting mid-fan-out leaves a
   half-upgraded mesh with no record of where it stopped. Run every node, report
   everything at the end.
4. **Verify the target's identity before executing anything mutating.** This is
   the one I'd most want you to take seriously. `FLEET_NODES` holds IPs; DHCP
   re-IPs a node; you now `curl … | sh` as root against whatever host holds that
   address today — potentially a workstation. Discovery already yields MACs from
   `cfg_device_list`; pin them, and confirm the remote unit is the expected
   device (and an ASUS unit at all) before running a mutating verb. A read-only
   `run` can be laxer; `install`/`push` must not be.
5. **Never write AiMesh-synced or security-relevant nvram; never restart
   `cfg_client`/`cfg_server`.** PLAN.md already commits to not writing
   `sshd_authkeys`. Make the broader rule explicit as a stated non-goal:
   fleetctl must not be able to break the user's mesh. An addon that corrupts
   cfg-sync is unrecoverable for a non-expert user.
6. **Exclude the controller from fan-out by default.** `cfg_device_list` lists
   the controller itself (role `1`). Fanning `install` onto self means a script
   rewriting itself while running — see the constraint above. Require an
   explicit opt-in flag for self-inclusion.
7. **Never prompt when there's no TTY.** If fleetctl is ever cron-driven (fleet
   auto-update is an obvious future ask), the `FLEET_ALLOW_PASSWORD` prompt
   would hang forever. Detect non-interactive invocation and fail with a clear
   message instead of blocking.
8. **Dry-run.** `--dry-run` printing exactly which command would run on which
   nodes. For a tool with this blast radius it's table stakes, and it's the
   natural way for a user to sanity-check their `FLEET_NODES` before trusting it.
9. **Single-instance lock.** Two overlapping fan-outs (manual + cron, or an
   impatient user) racing on the same node's `/jffs/scripts` is a corruption
   path. `flock` may not exist — verify; `mkdir` is the portable lock.
10. **Serial by default, deterministic output.** Meshes are small (2–4 units).
    Parallel fan-out interleaves lines unless you buffer per node, and it
    hammers a router CPU that is also routing. If you add parallelism later,
    buffer per node and keep the `[node]` prefix.
11. **Don't swallow the installer's stdout.** See §5 — for the doctor
    specifically, the installer's tail is the *only* place a silent misconfigure
    becomes visible.

## 4. The addon-installer contract (write this down; don't special-case us)

fleetctl is agnostic by design, so rather than knowing anything about the
doctor, **publish the contract an addon installer must satisfy to be
`fleetctl install`-able**. The doctor already satisfies all of it and can serve
as the reference implementation:

- **Non-interactive** — never reads stdin, never prompts. (Note the subtlety:
  the installer is *itself* arriving on stdin via curl-pipe-sh, so an installer
  that reads stdin is broken by construction. The doctor's workstation-side
  `setup.sh` handles this by reading prompts from `/dev/tty`; that's the escape
  hatch if an installer must prompt.)
- **Self-gating** — checks its own preconditions and exits non-zero with a
  human-readable reason. The doctor checks `/jffs` exists and
  `nvram get jffs2_scripts` = 1, so it fails clean on a stock node even if your
  eligibility gate somehow let it through. Belt and braces; keep both.
- **Idempotent** — re-running is the upgrade path, not an error.
- **Accepts arguments** — so `uninstall` and future subcommands work through the
  same verb. **This is a requirement on your `install` verb too**: support
  passing arguments through to the installer (the `sh -s -- <args>` idiom).
  Without it there is no fleet rollback, and a bad rollout across a mesh is
  exactly when the user needs one command to undo it. The doctor's installer
  takes `uninstall` as `$1`.
- **Ends with a verifiable health verdict** on stdout, non-zero exit on failure.

If you define this contract, other addon authors can target it — which is a
large part of why fleetctl deserves to be standalone.

## 5. The placebo problem — why "install succeeded" is not enough

Read this even though it sounds addon-specific; it generalizes into an output
requirement.

The doctor auto-detects which Wi-Fi interfaces to watch. On some hardware
classes that detection currently finds nothing and the addon silently falls back
to an inert configuration — installed, running, reporting itself started, and
doing **nothing**. The installer still exits 0 and still prints
`Installed and HEALING`. Only the health block at the tail reveals it.

Two consequences for you:

- **Requirement:** `install` must surface each node's installer output (at least
  its tail), not just a checkmark. A summary line alone would turn one silent
  misconfiguration into N invisible ones across a mesh, all self-reporting
  success.
- **Sequencing:** we consider mesh-wide `install` of the doctor gated on that
  detection bug being fixed first (flowcache-doctor issue #5). Fan-out
  multiplies confident false positives. You can build and test everything —
  `setup`, `discover`, `nodes`, `run`, `push`, the eligibility-skip path — before
  that lands; just don't *promote* mesh-wide doctor rollout until it does.

## 6. Heterogeneity — what the fleet actually looks like in the field

From flowcache-doctor's field testers (three real meshes, mixed hardware):

- **Firmware generations differ within one mesh.** We have a tester whose
  controller runs 3006 and whose node runs 3004. `cfg_device_list` format is
  verified on 3006 only. **Parse defensively**: on an unrecognized format, do
  not hard-fail — print the raw value and tell the user to populate
  `FLEET_NODES` manually. Discovery is a convenience; the tool must remain
  fully usable without it. (PLAN.md's "explicit `FLEET_NODES` is the source of
  truth" decision is correct — hold that line.)
- **Interface naming differs by hardware class and by role.** BE-class units use
  `wlX.Y` names; AX-class radios appear as `ethX`. The *same* mesh has different
  VAP indices on the controller vs its nodes. Don't build anything that assumes
  a naming scheme — and if you ever add per-node Wi-Fi introspection, treat it
  as model-dependent from day one.
- **Stock (non-Merlin) nodes are common and are legitimate `run` targets.** A
  stock AiMesh node still answers `nvram get`, `wl`, etc. Only `/jffs`-touching
  verbs need the Merlin gate. PLAN.md gets this right; keep the split.
- **When the eligibility gate fails, print the remediation, not just a verdict.**
  "node X: ineligible" is a dead end for a user. Tell them what to enable and
  where — and see the open question below, because for a node we do not yet know
  what that instruction actually is.

## 7. Open questions we want answered (some block usefulness)

Ordered by how much they affect whether fleetctl works for real users:

1. **How does a user enable JFFS custom scripts on an AiMesh *node*?** This is
   the gating precondition for installing any addon on a node, and an AiMesh
   node has no directly reachable web UI for the setting. Does `jffs2_scripts`
   sync from the controller the way `sshd_authkeys` does? Must it be set over
   SSH per node? At least one field tester has running installs on both their
   nodes, so there is a path — find out what it is. **If this has no clean
   answer, fleetctl's `install` verb is much less useful than it looks**, so
   answer it early.
2. **Does a node's `/jffs` survive AiMesh re-onboarding / re-sync?** If
   re-adding a node silently wipes the addon, then "installed" is not a durable
   state and `nodes` should be able to detect the drift. Unverified.
3. **cfg-sync latency for a GUI-pasted key** — live, or on reboot/re-sync? The
   whole one-paste trust model's ergonomics depend on the answer. Testable at
   home on the dev mesh.
4. **`DROPBEAR_PASSWORD` support in Merlin's dbclient build.** If it's not
   compiled in, drop the password fallback entirely and ship key-only — that's
   a better tool anyway.
5. **known-hosts / TOFU policy.** `-y` (blind accept) forever is the wrong
   default for a root-shell fan-out tool. Suggested: TOFU-pin on first contact
   into fleetctl's own known-hosts file (in `/tmp`? no — this one needs to
   persist, so `/jffs`, kept tiny), and warn loudly on change. A changed host
   key on a LAN node means firmware reflash *or* someone spoofing; the user
   should be told which they're accepting.
6. **`scp` vs `cat | ssh 'cat >'` for `push`** — dropbear scp has quirks. Verify
   on hardware rather than reasoning about it.

## 8. Smaller notes

- **Discoverability/PATH:** `/jffs/scripts` is not on `PATH`, so users cannot
  just type `fleetctl`. The doctor has a standing request for exactly this
  (issue #3). Solve it the same way in both projects so the ergonomics match.
- **amtm** is the addon manager Merlin users know. Worth deciding early whether
  fleetctl aims to be amtm-installable, since it affects packaging.
- **Audit trail:** for a tool that runs root shells on N devices, a small record
  of what was fanned out and when is justified — but mind the JFFS wear rule.
  Keep it tiny or keep it in `/tmp`.
- **Name collision** (`fleetctl` ↔ the dead CoreOS tool) is already flagged in
  PLAN.md; decide before publishing, since the install URL and docs bake it in.
