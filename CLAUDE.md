# CLAUDE.md

Contributor guidance for this repo lives in **`AGENTS.md`** — one file, so the
rules cannot drift between tools. It is imported below, and it is worth reading
in full before editing anything here: this repo ships busybox `sh` that opens
**root shells on other people's mesh nodes**, and most of its rules exist
because something failed on real hardware.

The three that bite hardest:

- **A failed node must never look like a successful run.** Per-node
  OK/FAIL/SKIPPED, non-zero exit on any failure, and never reduce a node to a
  checkmark.
- **Verify every applet AND every dbclient flag before relying on it.** There
  is no `timeout` applet and no `command` builtin on this firmware.
- **Test what you change.** `sh scripts/fleetctl.test.sh` (and `SH=dash …`) —
  the suite has already caught two silent-success bugs.

@AGENTS.md
