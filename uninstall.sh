#!/bin/sh
# uninstall.sh — remove fleetctl completely from an Asuswrt-Merlin router.
#
# Run ON the router:
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/uninstall.sh | sh
#
# Removes: the tool, the config, the keypair, our known_hosts, the PATH line,
# and any stale lock. Nothing else on your router is touched.
#
# NOT removed (fleetctl cannot undo what it never created):
#   - the public key you pasted into the router GUI's SSH authentication key
#     field. Remove it there if you are done with it; AiMesh propagates the
#     removal to every node.
#   - addons fleetctl installed on nodes. Roll those back FIRST, while fleetctl
#     is still here:  fleetctl install <installer-url> uninstall

# Same platform split as install.sh — `[ -d /jffs ]` plus an ASUS-only nvram
# variable, never `which nvram` (macOS ships its own unrelated one). Without
# this, running uninstall on a workstation looked in /jffs/scripts, found
# nothing, and left the real install in place while reporting success.
if [ -d /jffs ] && [ -n "$(nvram get productid 2>/dev/null)" ]; then
  DEST=/jffs/scripts
  CONFDIR=/jffs/scripts
  PROFILE=/jffs/configs/profile.add
else
  DEST="${FLEETCTL_BIN:-$HOME/.local/bin}"
  CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleetctl"
  PROFILE=""
fi
TOOL=$DEST/fleetctl

if [ -x "$TOOL" ]; then
  "$TOOL" uninstall
else
  echo "note: $TOOL not present — removing whatever artifacts remain."
  rm -f "$CONFDIR/fleetctl.conf" "$CONFDIR/fleetctl.key" "$CONFDIR/fleetctl.key.pub"
  rm -rf "$CONFDIR/fleetctl.d"
fi

[ -n "$PROFILE" ] && [ -f "$PROFILE" ] && sed -i '/# fleetctl PATH/d' "$PROFILE"
rm -f "$TOOL" /tmp/fleetctl.update.sh
rm -rf /tmp/fleetctl.lock

logger -t fleetctl "uninstalled" 2>/dev/null
echo "fleetctl uninstalled."
