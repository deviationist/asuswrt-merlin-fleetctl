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

DEST=/jffs/scripts
TOOL=$DEST/fleetctl
PROFILE=/jffs/configs/profile.add

if [ -x "$TOOL" ]; then
  "$TOOL" uninstall
else
  echo "note: $TOOL not present — removing whatever artifacts remain."
  rm -f "$DEST/fleetctl.conf" "$DEST/fleetctl.key" "$DEST/fleetctl.key.pub"
  rm -rf "$DEST/fleetctl.d"
fi

[ -f "$PROFILE" ] && sed -i '/# fleetctl PATH/d' "$PROFILE"
rm -f "$TOOL" /tmp/fleetctl.update.sh
rm -rf /tmp/fleetctl.lock

logger -t fleetctl "uninstalled" 2>/dev/null
echo "fleetctl uninstalled."
