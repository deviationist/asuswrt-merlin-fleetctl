# asuswrt-merlin-fleetctl

**Run commands, push files, and roll out addons across a whole AiMesh — with
one command, from the router itself or from your laptop.**

`amtm` manages one router. Addons that need to touch a mesh node each hand-roll
their own node SSH. `fleetctl` is the missing piece: generic fan-out plumbing —
discovery, trust, eligibility, timeouts, identity checks, per-node results —
that any addon can build on, with the security-sensitive machinery in one
auditable place instead of copied into every addon.

```
# on the AiMesh controller
fleetctl install https://raw.githubusercontent.com/<addon>/main/install.sh

=== node1 (admin@192.168.1.2:22) ===
[node1] Installed and HEALING
[node1] flowcache-doctor 0.3.1 health check
[node1]   ok:   poller running (pid 4711)
=== node2 (admin@192.168.1.3:22) ===
  not Merlin-eligible (RP-NODE-B: jffs2_scripts=empty, /jffs/scripts=no) — …

--- summary ---
  OK       node1              installer exited 0
  SKIPPED  node2              not Merlin-eligible …
  (1 ok, 0 failed, 1 skipped)
```

**Nothing in fleetctl is addon-specific.** Rollout, fleet-wide upgrade,
fleet-wide state and rollback are all the same generic verbs, and it will fan
out any installer that meets [the contract](#the-addon-installer-contract) —
or any bare command you like, on stock AiMesh nodes included.

It was extracted from
[flowcache-doctor](https://github.com/deviationist/asuswrt-merlin-flowcache-doctor),
which is its first consumer and the [worked
example](#worked-example-flowcache-doctor-across-a-mesh) below — but that addon
gets no special-casing in the code, and the design goal is explicitly the
general case: put the security-sensitive fan-out machinery in one auditable
place so no addon has to reinvent it.

---

## Install

The same installer works in both places and detects which it is on.

**On the router** (your AiMesh controller, SSH enabled, JFFS custom scripts on):

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/install.sh | sh
```

**On a workstation** (macOS/Linux) — installs to `~/.local/bin`, config in
`~/.config/fleetctl/`:

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/install.sh | sh
```

Re-running is the upgrade path (`fleetctl update` does exactly that). Your
config is never overwritten, and installing never creates or authorizes any
credentials — see [What fleetctl does not touch](#what-fleetctl-does-not-touch).

### Router or workstation?

|  | on the router | on a workstation |
|---|---|---|
| config | `/jffs/scripts/fleetctl.conf` | `~/.config/fleetctl/fleetctl.conf` |
| discovery | reads its own nvram | asks `FLEET_CONTROLLER` over SSH |
| auth | `FLEET_KEY` (one key, AiMesh-synced) | your existing `~/.ssh` — agent or `Host` block — or `FLEET_KEY` |
| `self` target | the controller, run locally | refused for `install`/`push` (not an ASUS unit) |

On a workstation fleetctl deliberately connects as a **bare host** when
`FLEET_USER` is empty, so your `~/.ssh/config` supplies user, port and key.
If you already have a `Host router` block, `FLEET_NODES="router"` just works.

## The trust model — one paste, no per-node steps

**You prepare the trust; fleetctl only consumes it.** fleetctl never writes
`sshd_authkeys` or any other security-relevant nvram.

If you do not already have a key that reaches the router, `fleetctl keygen`
writes one into fleetctl's own directory and prints the public half. (It is
never run for you — see [What fleetctl does not touch](#what-fleetctl-does-not-touch).
Already have a key? Point `FLEET_KEY` at it, or on a workstation just let
`~/.ssh` do its job.) Then:

1. Router GUI → **Administration → System → "SSH Authentication key"**
2. Paste the line on its **own line**, keeping any keys already there. Apply.

That is the whole setup. **AiMesh syncs that field byte-for-byte to every
node** — current *and* future — so every node accepts the key without being
touched individually. (Verified live on an RT-BE92U controller + RP-BE58 node:
`sshd_authkeys` is byte-identical on both, the node materialises it at
`/root/.ssh/authorized_keys`, and the `cfg_client` daemon carries it.)

Why fleetctl doesn't just write it for you: authorized-keys is the one setting
that can lock you out of your own mesh. It stays a human action in the GUI,
where the password escape hatch still works.

Side effect: the controller ends up authorising its own key. Harmless.

Then:

```sh
fleetctl discover                 # nodes + a ready-made FLEET_NODES line
# paste that line into /jffs/scripts/fleetctl.conf
fleetctl nodes                    # auth + eligibility per node
fleetctl --dry-run run 'uptime'   # confirm the target list before trusting it
```

## Verbs

| Verb | What it does | Needs |
|---|---|---|
| `keygen [--force]` | create a keypair, print the pubkey to paste (optional) | — |
| `discover` | parse `cfg_device_list` → pinned, conf-ready node specs | — |
| `nodes` | per-node auth / model / pin / eligibility | SSH |
| `run <cmd…>` | run a command on every node, output prefixed `[node]` | SSH |
| `push <local> <remote>` | copy a file to every eligible node, atomically | SSH + Merlin |
| `install <url> [args…]` | run an addon installer on every eligible node | SSH + Merlin |
| `health` | self-check; non-zero exit on any FAIL | — |
| `update` | self-update from `main` | curl |
| `uninstall` | remove fleetctl from this router | — |

Flags go **before** the verb, so everything after `run` / `install` belongs to
the remote command:

| Flag | Effect |
|---|---|
| `--dry-run` | probe and report; execute nothing |
| `--nodes "<spec> …"` | override `FLEET_NODES` for this invocation |
| `--include-self` | include the controller in the fan-out (off by default) |
| `--allow-unpinned` | let mutating verbs target nodes with no `mac=` pin |
| `--porcelain` | machine-readable per-node results, for consuming addons |

## Node specs — one list, however your mesh is reachable

`FLEET_NODES` is a space-separated list. Each entry is one whitespace-free
spec:

```
[user@]host[:port][,key=value]...
```

`host` may be an IP, a hostname, an `~/.ssh/config` alias, `[v6addr]` — or the
literal **`self`**, meaning *this machine, executed locally with no SSH hop*.
Fields:

| Field | Meaning |
|---|---|
| `port=` | SSH port for this node (default: `nvram sshd_port`, else 22) |
| `user=` | login for this node (default: `nvram http_username`, AiMesh-synced) |
| `key=` | identity file for this node (default: `FLEET_KEY`) |
| `auth=` | `pass` to use password auth for this node, `key` (default) otherwise |
| `mac=` | MAC pin — verified before anything mutating |
| `name=` | label used in output and summaries |

```sh
FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02,name=attic
             node3.lan:2222,user=admin,key=/jffs/scripts/node3.key,mac=AA:BB:CC:DD:EE:03"
```

So: same key everywhere, or one key per node; default port, or a custom one;
IPs, hostnames or SSH aliases; keys, or (reluctantly) a password. Paths in
`key=` must not contain spaces.

### `self` — including the unit you are running on

Running on the controller, you usually want the addon on *that* unit too:

```sh
FLEET_NODES="self 192.168.1.2,mac=AA:BB:CC:DD:EE:02"
```

`self` executes directly — no SSH hop, so the unit does not need to authorize
its own key. Listing it *is* the opt-in, so it is not subject to
`--include-self` (that flag guards the different, accidental case: a node whose
*address* happens to resolve to the controller). It needs no `mac=` pin either,
because a pin defends against an address pointing somewhere unexpected, and
there is no address involved.

`fleetctl discover` emits `self` for the controller when you run it there, and
an ordinary pinned spec when you run it from a workstation. On a workstation
`self` fails the mutating verbs, because your laptop is not an ASUS unit — the
same identity gate every other target goes through, no special case.

One guard: `fleetctl install <fleetctl's own installer>` with `self` in the
fleet is refused, because that would rewrite the running script. Use
`fleetctl update` for this machine.

## Config

`/jffs/scripts/fleetctl.conf` on a router, `~/.config/fleetctl/fleetctl.conf`
on a workstation — created by the installer with commented defaults, never
overwritten:

| Setting | Default | Notes |
|---|---|---|
| `FLEET_NODES` | `""` | the fleet. Runtime source of truth |
| `FLEET_CONTROLLER` | `self` on a router, else unset | who `discover` asks |
| `FLEET_USER` | `nvram http_username` on a router; empty on a workstation | empty = let `~/.ssh/config` decide |
| `FLEET_PORT` | `nvram sshd_port`, else 22 | |
| `FLEET_KEY` | `<confdir>/fleetctl.key` | optional; point it at any key you like |
| `FLEET_ALLOW_PASSWORD` | `0` | see below |
| `FLEET_STRICT_HOSTKEY` | `0` | `1` = refuse unknown host keys too |
| `FLEET_PROBE_TIMEOUT` | `20` | seconds |
| `FLEET_RUN_TIMEOUT` | `120` | seconds |
| `FLEET_INSTALL_TIMEOUT` | `600` | seconds |

Discovery is deliberately **not** the runtime source of truth: a discovered list
drifts (node offline, re-addressed), and a tool that opens root shells must aim
at a stable, user-owned target list.

## Safety model

One command, N devices, `curl … | sh` **as root** on each. That changes what
"correct" means, so:

- **Identity is verified before anything mutating.** Addresses move; `install`
  would otherwise run as root on whatever holds that address today — possibly a
  workstation. `install`/`push` require a `mac=` pin that matches the host that
  actually answered, plus proof it is an ASUS unit. `discover` emits pinned
  specs, so the safe path is the default one. `--allow-unpinned` is the explicit
  opt-out. `run` is deliberately laxer.
- **The controller is excluded** from fan-out unless `--include-self` (it lists
  itself in `cfg_device_list`, and installing onto self means a script rewriting
  itself while running).
- **Everything is timed out.** A node mid-reboot accepts TCP and then hangs.
  There is no `timeout` applet on this firmware, so fleetctl runs its own
  watchdog and reports a timeout as a timeout.
- **Continue on error.** Every node runs; failures are reported at the end.
  A half-run mesh with no record of where it stopped is worse.
- **A failed node never looks like success.** Per-node OK / FAIL /
  SKIPPED(reason), and a non-zero exit code if any node failed.
- **Installer output is never swallowed.** An addon can install cleanly, exit 0,
  and still be inert. Read the per-node output, not just the summary.
- **Single-instance lock**, so two fan-outs cannot race on one node's `/jffs`.
- **Host keys are trust-on-first-use** in fleetctl's own known_hosts
  (`/jffs/scripts/fleetctl.d/.ssh/known_hosts`): an unknown key is accepted and
  recorded, a **changed** key is refused. On a LAN node that means a firmware
  reflash — or someone else holding that address. fleetctl tells you both.
- **Never prompts without a TTY**, so a cron-driven fan-out fails instead of
  hanging forever.

Stated non-goals: fleetctl **never** writes `sshd_authkeys` or any AiMesh-synced
nvram, and **never** restarts `cfg_client`/`cfg_server`. It must not be able to
break your mesh.

## What fleetctl does not touch

fleetctl **consumes** credentials; it does not provision, install or manage
them. Provisioning is the operator's business, and deliberately outside this
tool. Concretely, fleetctl never:

- writes `sshd_authkeys`, or **any** nvram variable, on any unit;
- adds a public key to any `authorized_keys` file, anywhere;
- stores a password — the opt-in prompt keeps it in process memory for that one
  invocation and never writes it to disk;
- reads credentials from anywhere except the config you wrote;
- restarts `cfg_client` / `cfg_server`, or does anything else that could break
  AiMesh itself.

The config names *which* key, user, port or auth method to connect with. That is
the whole of fleetctl's involvement with credentials.

The one command that creates key material is **`keygen`**, and it is a
convenience you can ignore: it writes a keypair into fleetctl's own directory,
prints the public half, and authorizes nothing. It is never run for you — not by
the installer, not by another verb. Point `FLEET_KEY` at a key you already have,
or on a workstation let `~/.ssh` handle it, and `keygen` never needs to exist.

Authorizing the key stays a human action in the router GUI, on purpose:
authorized-keys is the one setting that can lock you out of your own mesh, and
the GUI is where the password escape hatch still works.

## Using fleetctl from your own addon

fleetctl is designed to be **depended on**, not vendored. Copying the fan-out
code into your addon recreates the exact problem this repo exists to solve — N
copies of security-sensitive SSH orchestration, each drifting. Depend on the
**CLI contract** instead.

**Detect it, don't bundle it:**

```sh
FLEETCTL=$(which fleetctl 2>/dev/null || echo /jffs/scripts/fleetctl)
if [ -x "$FLEETCTL" ]; then
  "$FLEETCTL" --porcelain run '/jffs/scripts/roamctl health'
else
  echo "Mesh commands need fleetctl:"
  echo "  curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/install.sh | sh"
fi
```

**`--porcelain` is a stable contract.** One tab-separated row per node:

```
fleetctl<TAB>node<TAB>OK|FAIL|SKIPPED<TAB>reason
```

Columns are never reordered or repurposed; anything new is appended. The exit
code is still non-zero if any node failed, so you can use either signal:

```sh
"$FLEETCTL" --porcelain install "$MY_INSTALLER" | while IFS="$(printf '\t')" read -r _ node state reason; do
  [ "$state" = "FAIL" ] && echo "$node did not take the update: $reason"
done
```

**Fleet state** has its own, wider row — it answers questions the summary
cannot (model, eligibility, pin state):

```
fleetctl-node<TAB>name<TAB>reachable|unreachable<TAB>model<TAB>eligible|ineligible<TAB>pin<TAB>detail
```

```sh
"$FLEETCTL" --porcelain nodes | while IFS="$(printf '\t')" read -r _ name state model elig pin _; do
  [ "$state" = "reachable" ] && [ "$elig" = "eligible" ] && echo "$name ($model) can take the addon"
done
```

Same append-only rule: columns are never reordered or repurposed.

**Library mode**, if you want fleetctl's plumbing rather than its verbs:

```sh
FLEETCTL_LIB=1 . /jffs/scripts/fleetctl     # loads, runs nothing

for spec in $(fleet_list); do
  fleet_spec "$spec"                        # -> SPEC_HOST SPEC_PORT SPEC_USER SPEC_MAC SPEC_NAME SPEC_LOCAL
  fleet_probe || continue                   # -> P_MODEL P_JFFS P_DIR P_MACS P_REASON
  fleet_eligible && fleet_exec 60 'my command'
done
```

The `fleet_*` functions are the stable surface: `fleet_version`,
`fleet_platform`, `fleet_list`, `fleet_spec`, `fleet_probe`, `fleet_eligible`,
`fleet_gate`, `fleet_exec`. Underscore-prefixed internals are not — they change
between releases. Gate on `fleet_version` if you need a specific behaviour.

Prefer the CLI unless you have a concrete reason: it is version-tolerant, and it
keeps the fan-out safety model (gates, timeouts, summary, exit code) working for
you rather than something you have to reimplement.

## Password login (supported reluctantly, discouraged loudly)

Key auth is the design. `FLEET_ALLOW_PASSWORD=1` (or `auth=pass` on a spec)
exists only as an explicit escape hatch for "I just want to try it": the
password is prompted for once, never echoed, and **never stored** — no
password ever lands in a conf file, a script, or JFFS. It does transit process
environments (`DROPBEAR_PASSWORD`, which Merlin's dbclient supports). Set up the
key instead; it is one paste.

## The addon-installer contract

fleetctl is agnostic by design. Rather than knowing anything about a specific
addon, it publishes the contract an installer must satisfy to be
`fleetctl install`-able:

1. **Non-interactive** — never reads stdin, never prompts. (fleetctl downloads
   your installer to a file and runs it, so stdin is free — but an installer
   that prompts still hangs a fan-out. If you must prompt, read from `/dev/tty`.)
2. **Self-gating** — check your own preconditions (`/jffs` present,
   `nvram get jffs2_scripts` = 1) and exit non-zero with a human-readable
   reason. fleetctl gates too; belt and braces.
3. **Idempotent** — re-running is the upgrade path, not an error.
4. **Accepts arguments** — `install <url> uninstall` is how a user rolls a bad
   fleet-wide rollout back, so take `uninstall` as `$1`.
5. **Ends with a verifiable health verdict** on stdout, non-zero exit on
   failure. Print it; fleetctl shows it per node.

[flowcache-doctor](https://github.com/deviationist/asuswrt-merlin-flowcache-doctor)
is the reference implementation.

## Worked example: flowcache-doctor across a mesh

flowcache-doctor is fleetctl's first consumer and the addon this design was
extracted from — but it gets **no special-casing whatsoever**. Everything below
is the generic verbs, and any addon meeting the contract above works the same
way. That is the point of the tool.

The doctor heals a Broadcom flow-cache bug where a Wi-Fi client loses specific
wired LAN hosts after a band roam. In a mesh, clients roam *between units*, so
the addon wants to run on every unit — which used to mean SSHing into each node
by hand.

```sh
DOCTOR=https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh

# see what would happen, and to which units, before trusting the list
fleetctl --dry-run install "$DOCTOR"

# roll it out
fleetctl install "$DOCTOR"

# is it actually working on every unit? (this is the question that matters)
fleetctl run '/jffs/scripts/roamctl health'

# upgrade the whole mesh — same command, the installer is idempotent
fleetctl install "$DOCTOR"

# roll the whole mesh back
fleetctl install "$DOCTOR" uninstall
```

Four of those five need no addon-specific code at all — `run` covers fleet-wide
state, and `install` re-run covers upgrade. Note `roamctl health` exits non-zero
on any FAIL, and fleetctl preserves that per node and in its own exit code, so
the two compose into one trustworthy answer.

Two caveats specific to this pairing, stated because they change what you
should expect:

- **A unit that is not Merlin gets skipped, with the reason printed.** In a
  mixed mesh (a stock AiMesh node is common) the summary will say `SKIPPED`,
  not `OK` — that is correct behaviour, not a failure to roll out.
- **Read the per-node installer output, not just the summary.** The doctor
  auto-detects which Wi-Fi interfaces to watch, and on some hardware that
  detection can land in an inert configuration while still printing
  `Installed and HEALING` and exiting 0. Fan-out multiplies confident false
  positives; fleetctl deliberately prints every node's installer tail so a
  silent misconfigure stays visible instead of becoming N invisible ones.

## Enabling JFFS custom scripts on a node

`install` and `push` require the target to be a Merlin unit with JFFS custom
scripts enabled (`nvram get jffs2_scripts` = 1 **and** `/jffs/scripts` present).
A stock AiMesh node returns an empty `jffs2_scripts` and is skipped with that
reason — it remains a perfectly good `run` target.

**This is the one prerequisite we cannot yet give a verified recipe for.** An
AiMesh node has no web UI of its own, so the controller's *Administration →
System* page is not a path to the node's setting, and we have not yet confirmed
whether `jffs2_scripts` propagates from the controller the way `sshd_authkeys`
does, or must be set per node over SSH. Field testers do have addons running on
their nodes, so a path exists — it is [open question #1](CONSUMER-BRIEF.md) and
will be documented here once verified rather than guessed at. Until then,
`fleetctl run` works on every node regardless.

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `SSH auth failed` | the key is not authorized yet — paste it into the GUI field and Apply |
| `HOST KEY MISMATCH` | that address answered with a different host key: a reflash, or another host holds it now. Verify, then remove the entry from `/jffs/scripts/fleetctl.d/.ssh/known_hosts` |
| `no MAC pin` | mutating verbs need `mac=` — re-run `fleetctl discover` for pinned specs |
| `does not match this host` | DHCP moved the address. Re-run `fleetctl discover` |
| `not Merlin-eligible` | stock node, or JFFS custom scripts off — see above |
| `cfg_device_list is empty` | not the controller, or no nodes. Populate `FLEET_NODES` by hand |
| `password auth needs a terminal` | a cron/piped invocation cannot prompt. Use key auth |

`fleetctl health` checks all of this in one pass and exits non-zero on any FAIL.

## Uninstall

```sh
fleetctl install <addon-installer-url> uninstall   # roll addons back FIRST
sh /jffs/scripts/fleetctl uninstall                # or: sh install.sh uninstall
```

Removes the tool, conf, keypair, known_hosts and PATH line. It does **not**
remove the public key from your GUI field — do that in the router GUI if you
are done with it; AiMesh propagates the removal to the nodes.

## Status

v0.2.0. Exercised by 143 offline tests (`sh scripts/fleetctl.test.sh`, and
again under `dash`) and validated against a dev mesh (RT-BE92U 3006 controller +
stock RP-BE58 node): discovery parsing, key auth into a node, the eligibility
skip path and the MAC-pin check are all confirmed on real hardware. The
`install` happy path still needs a **Merlin** node to be validated in the field.
See `PLAN.md` for what is verified vs. still open, and `AGENTS.md` if you are
contributing.

## License

MIT
