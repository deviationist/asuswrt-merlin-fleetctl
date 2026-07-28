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

fail() { echo "ERROR: $1" >&2; exit 1; }

# fleetctl runs on the router AND on a workstation, so the installer has to
# know which one it is looking at. Detection is `[ -d /jffs ]` + an ASUS-only
# nvram variable, NOT `which nvram`: macOS ships its own unrelated
# /usr/sbin/nvram and would otherwise be mistaken for a router.
if [ -d /jffs ] && [ -n "$(nvram get productid 2>/dev/null)" ]; then
  PLATFORM=router
  DEST=/jffs/scripts
  CONFDIR=/jffs/scripts
  PROFILE=/jffs/configs/profile.add
  [ "$(nvram get jffs2_scripts)" = "1" ] || fail "JFFS custom scripts are disabled.
Enable: Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
hit Apply, then re-run this installer."
else
  PLATFORM=workstation
  DEST="${FLEETCTL_BIN:-$HOME/.local/bin}"
  CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/fleetctl"
  PROFILE=""
  command -v sh >/dev/null 2>&1 || fail "no POSIX shell?"
fi
TOOL=$DEST/fleetctl
CONF=$CONFDIR/fleetctl.conf
HOMEDIR=$CONFDIR/fleetctl.d

if [ "$1" = "uninstall" ]; then
  [ -x "$TOOL" ] && "$TOOL" uninstall
  [ -n "$PROFILE" ] && [ -f "$PROFILE" ] && sed -i '/# fleetctl PATH/d' "$PROFILE"
  rm -f "$TOOL" "$CONF" "$CONFDIR/fleetctl.key" "$CONFDIR/fleetctl.key.pub" /tmp/fleetctl.update.sh
  rm -rf "$HOMEDIR" /tmp/fleetctl.lock
  echo "fleetctl uninstalled."
  exit 0
fi

mkdir -p "$DEST" "$CONFDIR"

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

# Which unit 'discover' asks for the mesh list. On a router this defaults to
# itself; on a workstation fleetctl falls back to the LAN default gateway and
# confirms what it finds. Set it explicitly if you reach the router through an
# SSH alias (a Host block supplies the user and key that a bare IP does not).
#FLEET_CONTROLLER=""

# Defaults inherited by every node that does not override them.
#FLEET_USER=""                          # empty => nvram http_username (AiMesh syncs it mesh-wide)
#FLEET_PORT=""                          # empty => nvram sshd_port, else 22
#FLEET_KEY="/jffs/scripts/fleetctl.key" # a key YOU created and authorized;
                                        # leave unset on a workstation to let
                                        # ~/.ssh (agent or Host block) decide

# Password auth: supported reluctantly, discouraged loudly. With this on, the
# password is prompted for once per invocation and kept in memory only — it is
# NEVER written to this file or any other, because that would leave a plaintext
# mesh-admin credential on flash.
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
if [ "$PLATFORM" = "router" ] && [ "$1" != "--no-path" ]; then
  mkdir -p /jffs/configs
  [ -f "$PROFILE" ] || : > "$PROFILE"
  grep -q '# fleetctl PATH' "$PROFILE" 2>/dev/null ||
    echo 'export PATH="$PATH:/jffs/scripts"   # fleetctl PATH' >> "$PROFILE"
fi

echo "fleetctl installed at $TOOL ($PLATFORM)"
echo

# Deliberately creates no credentials. Getting access to your own routers is
# the operator's business; fleetctl's business is distributing an addon using
# the credentials the config names. There is no key-generation command at all —
# see README, "What fleetctl does not touch".
if [ "$PLATFORM" = "router" ]; then
  cat <<EOF
Next:

  1. Make sure fleetctl can log in to your units. That part is yours, not
     fleetctl's: point FLEET_KEY at a key you already use, or make one with
         dropbearkey -t ed25519 -f $CONFDIR/fleetctl.key
         dropbearkey -y -f $CONFDIR/fleetctl.key      # public half, to authorize
     Pasting it into the router GUI (Administration -> System -> "SSH
     Authentication key") authorizes it on every node at once — AiMesh syncs
     that field mesh-wide, so it is the only per-mesh step.

  2. fleetctl discover                 # nodes + a conf-ready FLEET_NODES line
  3. fleetctl nodes                    # verify auth + eligibility per node
  4. fleetctl --dry-run run 'uptime'   # confirm the target list before trusting it
  5. fleetctl health                   # self-check

(Open a new SSH session, or run '. $PROFILE', to get 'fleetctl' on your PATH.)
EOF
else
  cat <<EOF
Next:

  1. Point fleetctl at your mesh in $CONF:
         FLEET_CONTROLLER="192.168.1.1"   # or a Host alias from ~/.ssh/config
     If your ~/.ssh already reaches the router (agent, or a Host block), there
     is nothing else to set up — leave FLEET_KEY unset and OpenSSH decides.
     Otherwise make one with ssh-keygen and authorize it on the router the way
     you normally would (the GUI's "SSH Authentication key" field syncs it to
     every node at once).

  2. fleetctl discover                 # nodes + a conf-ready FLEET_NODES line
  3. fleetctl nodes                    # verify auth + eligibility per node
  4. fleetctl --dry-run run 'uptime'   # confirm the target list before trusting it

EOF
  case ":$PATH:" in
    *":$DEST:"*) : ;;
    *) echo "note: $DEST is not on your PATH — add it, or call $TOOL directly."; echo ;;
  esac
fi
echo "Uninstall:  sh install.sh uninstall    (or: fleetctl uninstall)"
