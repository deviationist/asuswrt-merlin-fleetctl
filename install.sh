#!/bin/sh
# install.sh — fleetctl installer for Asuswrt-Merlin.
#
# Run ON the router that is your AiMesh CONTROLLER (after enabling SSH + JFFS
# custom scripts, see README):
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main/install.sh | sh
#
# Or from a clone of this repo copied to the router:
#   sh install.sh
#
# Re-running is the upgrade path (this is also what `fleetctl update` execs).
# Your config is never overwritten.
#
# Uninstall:  sh install.sh uninstall

REPO_RAW="https://raw.githubusercontent.com/deviationist/asuswrt-merlin-fleetctl/main"
DEST=/jffs/scripts
TOOL=$DEST/fleetctl
CONF=$DEST/fleetctl.conf
HOMEDIR=$DEST/fleetctl.d
PROFILE=/jffs/configs/profile.add

fail() { echo "ERROR: $1" >&2; exit 1; }

[ -d /jffs ] || fail "no /jffs mount — is this an Asuswrt-Merlin router?"
[ "$(nvram get jffs2_scripts)" = "1" ] || fail "JFFS custom scripts are disabled.
Enable: Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
hit Apply, then re-run this installer."

if [ "$1" = "uninstall" ]; then
  [ -x "$TOOL" ] && "$TOOL" uninstall
  [ -f "$PROFILE" ] && sed -i '/# fleetctl PATH/d' "$PROFILE"
  rm -f "$TOOL" "$CONF" "$DEST/fleetctl.key" "$DEST/fleetctl.key.pub" /tmp/fleetctl.update.sh
  rm -rf "$HOMEDIR" /tmp/fleetctl.lock
  echo "fleetctl uninstalled."
  exit 0
fi

mkdir -p "$DEST"

# Fetch the tool (prefer a local copy when run from a checkout).
# NOTE: this never writes over a RUNNING fleetctl in place from fleetctl's own
# process — `fleetctl update` execs this installer first, so the process is
# replaced before its file is. busybox sh reads scripts incrementally; a script
# whose file is rewritten mid-execution is undefined behavior.
if [ -f ./scripts/fleetctl ]; then
  cp ./scripts/fleetctl "$TOOL" || fail "could not copy scripts/fleetctl"
else
  # ?cb= busts the raw.githubusercontent.com CDN cache (raw itself can still
  # lag a push by ~5 minutes — that is not a failed install, just a stale fetch)
  curl -fsSL "$REPO_RAW/scripts/fleetctl?cb=$(date +%s)" -o "$TOOL.new" || fail "download of fleetctl failed — does the router have internet access?"
  [ -s "$TOOL.new" ] || fail "downloaded fleetctl is empty"
  sh -n "$TOOL.new" || fail "downloaded fleetctl does not parse — refusing to install it"
  mv "$TOOL.new" "$TOOL"
fi
chmod 755 "$TOOL"

# Config: created once with commented defaults, NEVER overwritten (it holds the
# user's node list, which is the one thing here we must not clobber).
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<'EOF'
# fleetctl configuration — sourced by /jffs/scripts/fleetctl (busybox sh).
# Everything here is optional; the defaults are shown commented out.

# The fleet. Space-separated node specs; this is the runtime source of truth
# (discovery is only ever a suggestion — a discovered list drifts when a node
# is offline or re-addressed). Run 'fleetctl discover' for a ready-made line.
#
#   spec:   [user@]host[:port][,key=value]...
#   fields: port=  user=  key=<identity file>  auth=pass|key  mac=<pin>  name=<label>
#
#   FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:FF,name=node1 192.168.1.3,mac=AA:BB:CC:DD:EE:03"
#
# The mac= pins are not decoration: addresses move (DHCP), and 'install'/'push'
# run as root on whatever answers. fleetctl verifies the pin first and refuses
# a mismatch. Paths in key= must not contain spaces.
FLEET_NODES=""

# Defaults inherited by every node that does not override them.
#FLEET_USER=""                          # empty => nvram http_username (AiMesh syncs it mesh-wide)
#FLEET_PORT=""                          # empty => nvram sshd_port, else 22
#FLEET_KEY="/jffs/scripts/fleetctl.key" # created by 'fleetctl setup'

# Password auth: supported reluctantly, discouraged loudly. Key auth is one
# paste ('fleetctl setup'). With this on, the password is prompted for once per
# invocation and kept in memory only — it is NEVER written to this file or any
# other, because that would leave a plaintext mesh-admin credential on flash.
#FLEET_ALLOW_PASSWORD=0

# Host keys are trust-on-first-use by default: an UNKNOWN key is accepted and
# recorded in /jffs/scripts/fleetctl.d/.ssh/known_hosts, a CHANGED key is always
# refused. Set to 1 to refuse unknown keys too (pre-seed known_hosts yourself).
#FLEET_STRICT_HOSTKEY=0

# Per-node wall-clock caps, in seconds. A node mid-reboot accepts TCP and then
# hangs; without these one sick unit would stall the whole fan-out.
#FLEET_PROBE_TIMEOUT=20
#FLEET_RUN_TIMEOUT=120
#FLEET_INSTALL_TIMEOUT=600
EOF
  chmod 644 "$CONF"
  echo "Created $CONF"
else
  echo "Kept existing $CONF"
fi

# /jffs/scripts is not on PATH, so `fleetctl` alone would not resolve. Merlin
# sources /jffs/configs/profile.add for interactive shells; one guarded line
# there is the least invasive fix, and uninstall removes it.
if [ "$1" != "--no-path" ]; then
  mkdir -p /jffs/configs
  [ -f "$PROFILE" ] || : > "$PROFILE"
  grep -q '# fleetctl PATH' "$PROFILE" 2>/dev/null ||
    echo 'export PATH="$PATH:/jffs/scripts"   # fleetctl PATH' >> "$PROFILE"
fi

echo "fleetctl installed at $TOOL"
echo

# Generate the keypair and print it: 'setup' only creates files in fleetctl's
# own path and prints the pubkey — it writes no nvram, so it is safe to run
# unattended as part of an install. The one action that could lock someone out
# (authorizing the key) stays a human step in the GUI.
"$TOOL" setup

cat <<EOF

After pasting the key and applying:

  fleetctl discover                 # nodes + a conf-ready FLEET_NODES line
  fleetctl nodes                    # verify auth + eligibility per node
  fleetctl --dry-run run 'uptime'   # confirm the target list before trusting it
  fleetctl health                   # self-check

(Open a new SSH session, or run '. $PROFILE', to get 'fleetctl' on your PATH.)

Uninstall:  sh install.sh uninstall    (or: fleetctl uninstall)
EOF
