#!/bin/sh
# canary.sh — a deliberately inert addon installer.
#
# Purpose: let someone exercise `fleetctl install` end to end — download, run as
# root, per-node output, exit status, summary — WITHOUT changing anything that
# survives a reboot. Most people's AiMesh is production kit and the only one
# they own; "just try installing something" is otherwise a bad first move.
#
#   fleetctl --dry-run install https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/extras/canary.sh
#   fleetctl --yes     install https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/extras/canary.sh
#   fleetctl --yes     install https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/extras/canary.sh uninstall
#
# It writes exactly one file, /tmp/fleetctl-canary (RAM, gone on reboot), and
# touches no nvram, no /jffs, no cron, no boot hook.
#
# It doubles as the reference implementation of the addon-installer contract in
# fleetctl's README:
#   1. non-interactive   — never reads stdin, never prompts
#   2. self-gating       — checks its own preconditions, exits non-zero with a reason
#   3. idempotent        — re-running is the upgrade path, not an error
#   4. accepts arguments — `uninstall` as $1, so fleet rollback works
#   5. health verdict    — prints what it found, non-zero exit on failure
MARKER=/tmp/fleetctl-canary
VERSION=1.0

if [ "$1" = "uninstall" ]; then
  if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    echo "canary $VERSION: removed $MARKER"
  else
    echo "canary $VERSION: nothing to remove (already absent)"
  fi
  echo "canary $VERSION: uninstalled cleanly."
  exit 0
fi

# (2) Self-gating. A real addon checks what it needs and fails clean; fleetctl
# gates too, and both layers are deliberate. The canary asks for the same
# preconditions a /jffs-installing addon would, so a stock node fails here
# exactly as it would there.
[ -d /jffs ] || { echo "canary $VERSION: FAIL — no /jffs (not an Asuswrt-Merlin unit?)"; exit 1; }
[ "$(nvram get jffs2_scripts 2>/dev/null)" = "1" ] ||
  { echo "canary $VERSION: FAIL — JFFS custom scripts are not enabled on this unit"; exit 1; }

# (3) Idempotent: say which it was, but succeed either way.
if [ -f "$MARKER" ]; then
  echo "canary $VERSION: already present, re-running (this is the upgrade path)"
else
  echo "canary $VERSION: first install on this unit"
fi

{
  echo "installed-by=fleetctl-canary"
  echo "version=$VERSION"
  echo "model=$(nvram get productid 2>/dev/null)"
} > "$MARKER" 2>/dev/null || { echo "canary $VERSION: FAIL — could not write $MARKER"; exit 1; }

# (5) A verifiable verdict on stdout. fleetctl prints this per node, which is
# the whole point: an addon can exit 0 and still be inert, and the tail is
# where that shows.
echo "canary $VERSION health check"
echo "  ok:   running on $(nvram get productid 2>/dev/null)"
echo "  ok:   marker present: $MARKER"
echo "  ok:   wrote nothing outside /tmp — no nvram, no /jffs, no cron, no boot hook"
echo "canary $VERSION: healthy. Nothing here survives a reboot."
exit 0
