#!/bin/sh
# fleetctl.test.sh — black-box tests for fleetctl's fan-out logic.
#
# Mocks the router side (nvram / dbclient / dropbearkey / logger) with state in
# a temp dir and runs the REAL fleetctl against it. No router needed.
#   Run:  sh scripts/fleetctl.test.sh
#   Also: SH=dash sh scripts/fleetctl.test.sh   (dash is much closer to the
#         router's busybox ash than macOS bash-as-sh)
#
# What it locks in: spec parsing, the identity/pin gate, the eligibility gate,
# self-exclusion, continue-on-error, per-node exit-status preservation, the
# timeout watchdog, dry-run, the lock, and the discovery parser (including its
# defensive paths).
#
# What it does NOT cover — router-only, verified live over SSH:
#   - whether dbclient actually authenticates with a dropbear-format key
#   - whether AiMesh really syncs sshd_authkeys to a node (verified 2026-07-22)
#   - real cfg_device_list values on firmware generations other than 3006
#
# NB: every address and MAC below is an RFC-5737-style placeholder. Never paste
# real discovery output into this file — it is full of real MACs and hostnames.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FLEETCTL="$HERE/fleetctl"
SH="${SH:-sh}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/hosts"
export NVRAM_STATE="$TMP/nvram"
export FLEET_TEST_DIR="$TMP"
export FLEETCTL_CONF="$TMP/conf" FLEETCTL_HOME="$TMP/home" FLEETCTL_LOCK="$TMP/lock"
# The probed /jffs path, redirected so a `self` target can be made to look
# eligible (or not) on the test machine. The suite runs as PLATFORM=workstation
# — there is no /jffs on a Mac or a CI box — which is itself worth knowing: the
# off-router paths are the ones exercised by default here.
export FLEETCTL_JFFS="$TMP/jffs"
export PATH="$BIN:$PATH"

# --- mock router commands ---------------------------------------------------
cat > "$BIN/nvram" <<'M'
#!/bin/sh
S="$NVRAM_STATE"
case "$1" in
  get) l=$(grep "^$2=" "$S" 2>/dev/null | head -1); echo "${l#*=}" ;;
  set) k="${2%%=*}"; v="${2#*=}"; grep -v "^$k=" "$S" 2>/dev/null > "$S.t"; printf '%s=%s\n' "$k" "$v" >> "$S.t"; mv "$S.t" "$S" ;;
  commit) : ;;
esac
M

# mock dbclient: dispatches on a per-host fixture file (sourced), so a test can
# make a node unreachable, unauthenticated, stock, slow, or failing.
cat > "$BIN/dbclient" <<'M'
#!/bin/sh
if [ "$1" = "-h" ]; then
  printf '%s\n' 'Dropbear SSH client v2026.91' '-p <remoteport>' '-i <identityfile>' \
    '-K <keepalive>  (0 is never, default 0)' '-M <max_duration>  (0 is off, default 0, in seconds)'
  exit 0
fi
if [ "$1" = "-o" ] && [ "$2" = "help" ]; then
  printf '%s\n' 'dbclient: Available options:' '  BatchMode' '  PasswordAuthentication'
  exit 1
fi
printf 'ARGS: %s\n' "$*" >> "$FLEET_TEST_DIR/sshlog"
target=""; cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|-i|-K|-M|-l|-o|-c|-m) shift 2 ;;
    -*) shift ;;
    *) if [ -z "$target" ]; then target=$1; else cmd="$cmd $1"; fi; shift ;;
  esac
done
host=${target#*@}
f="$FLEET_TEST_DIR/hosts/$host"
[ -f "$f" ] || { echo "ssh: Connection to $host failed: No route to host" >&2; exit 255; }
auth=ok; model=""; jffs=""; dir=no; on=1; macs=""; rc=0; sleepsec=0
. "$f"
[ "$sleepsec" != "0" ] && sleep "$sleepsec"
case "$auth" in
  ok) : ;;
  hostkey) echo "Host key mismatch for $host !" >&2; exit 255 ;;
  prompt)  printf "%s@%s's password: " "${target%%@*}" "$host" >&2; exit 255 ;;
  noauth)  echo "dbclient: Connection to $target exited: No auth methods could be used." >&2; exit 255 ;;
  *) echo "dbclient: Authentication failed" >&2; exit 255 ;;
esac
case "$cmd" in
  *__fleetprobe__*) echo "__fleetprobe__ v=1 model=$model jffs=$jffs dir=$dir on=${on:-1} macs=$macs"; exit 0 ;;
  *cfg_device_list*) cat "$FLEET_TEST_DIR/cfg_device_list"; exit 0 ;;
  *"cat > "*)       cat > "$FLEET_TEST_DIR/pushed-$host"; exit "$rc" ;;
  *"curl -fsSL"*)   printf '%s\n' "$cmd" >> "$FLEET_TEST_DIR/installcmd-$host"
                    echo "roam-detect installed"; echo "Installed and HEALING"; exit "$rc" ;;
  *)                echo "output-from-$host"; exit "$rc" ;;
esac
M

cat > "$BIN/dropbearkey" <<'M'
#!/bin/sh
f=""; y=0
while [ $# -gt 0 ]; do
  case "$1" in -f) f=$2; shift 2 ;; -y) y=1; shift ;; -t|-s) shift 2 ;; *) shift ;; esac
done
if [ "$y" = 1 ]; then
  [ -f "$f" ] || { echo "Failed reading key" >&2; exit 1; }
  echo "Public key portion is:"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLACEHOLDERPLACEHOLDERPLACEHOLDER fleetctl@router"
  echo "Fingerprint: SHA256:placeholder"
  exit 0
fi
[ -n "$f" ] || exit 1
echo "MOCK-PRIVATE-KEY" > "$f"
M
printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"
# mock curl: only reached by a LOCAL (`self`) install, where the download runs
# on this machine. Writes a stand-in addon installer to the -o path.
cat > "$BIN/curl" <<'M'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] || exit 1
printf '#!/bin/sh\necho "addon installed on $(hostname 2>/dev/null || echo host)"\necho "Installed and HEALING"\nexit 0\n' > "$out"
M
chmod +x "$BIN"/*

# --- fixtures ---------------------------------------------------------------
host_fixture() { # host auth model jffs dir macs rc sleep
  cat > "$TMP/hosts/$1" <<EOF
auth=$2
model=$3
jffs=$4
dir=$5
macs=$6
rc=$7
sleepsec=$8
EOF
}
CDL='<controller>192.168.1.1>AA:BB:CC:DD:EE:01>1<node1>192.168.1.2>AA:BB:CC:DD:EE:02>0<node2>192.168.1.3>AA:BB:CC:DD:EE:03>0'
reset() {
  printf '%s\n' \
    'http_username=admin' 'sshd_port=22' 'jffs2_scripts=1' \
    'productid=RT-PLACEHOLDER' 'lan_ipaddr=192.168.1.1' 'lan_hwaddr=AA:BB:CC:DD:EE:01' \
    'label_mac=AA:BB:CC:DD:EE:01' \
    "cfg_device_list=$CDL" \
    > "$NVRAM_STATE"
  printf '%s\n' "$CDL" > "$TMP/cfg_device_list"   # what a remote controller returns
  mkdir -p "$TMP/jffs"                            # `self` looks Merlin-eligible
  rm -rf "$TMP/hosts" "$TMP/home" "$TMP/lock" "$TMP/sshlog" "$TMP"/pushed-* "$TMP"/installcmd-*
  rm -f "$TMP/fleetctl.key" "$TMP/fleetctl.key.pub"   # tests opt in via withkey
  mkdir -p "$TMP/hosts"
  #            host          auth  model        jffs dir macs                     rc sleep
  host_fixture 192.168.1.1   ok    RT-PLACEHDR  1    yes "AA:BB:CC:DD:EE:01,"     0  0   # controller (self)
  host_fixture 192.168.1.2   ok    RT-NODE-A    1    yes "AA:BB:CC:DD:EE:02,"     0  0   # Merlin node
  host_fixture 192.168.1.3   ok    RP-NODE-B    ""   no  "AA:BB:CC:DD:EE:03,"     0  0   # stock node
  host_fixture 192.168.1.4   deny  ""           ""   no  ""                       0  0   # auth fails
  host_fixture 192.168.1.5   hostkey ""         ""   no  ""                       0  0   # host key changed
  : > "$FLEETCTL_CONF"; rm -f "$FLEETCTL_CONF.bak"
}
conf() { printf '%s\n' "$@" > "$FLEETCTL_CONF"; }
KEY="$TMP/fleetctl.key"
withkey() { echo "MOCK-PRIVATE-KEY" > "$KEY"; chmod 600 "$KEY"; }

# --- harness ----------------------------------------------------------------
PASS=0; FAIL=0
run() { "$SH" "$FLEETCTL" "$@"; }
# Platform-forced variant. NOT `FLEETCTL_PLATFORM=x run …`: a var assignment
# preceding a FUNCTION call persists in the shell under POSIX rules, so it
# would leak into every later test. Prefixing an external command is scoped.
runp() { _p=$1; shift; FLEETCTL_PLATFORM="$_p" "$SH" "$FLEETCTL" "$@"; }
has()   { case "$2" in *"$3"*) PASS=$((PASS+1)); printf '  ok   %s\n' "$1";; *) FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "$1" "$(echo "$2" | tr '\n' '|' | cut -c1-300)";; esac; }
hasnt() { case "$2" in *"$3"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n       unexpectedly got: %s\n' "$1" "$(echo "$2" | tr '\n' '|' | cut -c1-300)";; *) PASS=$((PASS+1)); printf '  ok   %s\n' "$1";; esac; }
is()    { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s | got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }
nonzero(){ if [ "$2" != "0" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s | expected non-zero exit\n' "$1"; fi; }

echo "fleetctl tests ($SH):"

# === discover ===============================================================
echo "-- discover"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="self"'
out=$(run discover 2>&1)
has  "discover: finds node1"                  "$out" "192.168.1.2"
has  "discover: finds node2"                  "$out" "192.168.1.3"
has  "discover: includes the controller"      "$out" "[controller]"
has  "discover: controller offered as 'self'" "$out" "self (192.168.1.1)"
has  "discover: suggests a FLEET_NODES line"  "$out" 'FLEET_NODES="'
has  "discover: pins MACs in the suggestion"  "$out" "mac=AA:BB:CC:DD:EE:03"
has  "discover: self spec needs no pin"       "$out" "self,name=controller"
has  "discover: labels the Merlin node"       "$out" "merlin: yes"
has  "discover: labels the stock node"        "$out" "merlin: no"
has  "discover: explains why pins matter"     "$out" "pins are not decoration"
has  "discover: says the controller is optional" "$out" "Delete it if you only want the nodes"

# from a workstation: no local nvram to ask, so discovery hops to the controller
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="192.168.1.1"'
out=$(run discover 2>&1)
has  "discover: fetches the list over SSH"    "$(cat "$TMP/sshlog")" "cfg_device_list"
has  "discover: remote controller yields nodes" "$out" "192.168.1.2"
has  "discover: remote controller is a normal SSH target" "$out" "192.168.1.1,mac=AA:BB:CC:DD:EE:01"
hasnt "discover: no 'self' when the controller is remote" "$out" "self,name="

reset; withkey; conf "FLEET_KEY=\"$KEY\""
out=$(run discover 2>&1); rc=$?
nonzero "discover: no controller configured exits non-zero" "$rc"
has  "discover: says how to set the controller" "$out" "FLEET_CONTROLLER="

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="self"'
sed -i.bak '/^cfg_device_list=/d' "$NVRAM_STATE"
out=$(run discover 2>&1); rc=$?
nonzero "discover: empty list exits non-zero" "$rc"
has  "discover: empty list explains what to do next" "$out" 'FLEET_NODES="self"'

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="self"'
sed -i.bak 's/^cfg_device_list=.*/cfg_device_list=SOMETHING-UNPARSEABLE-FROM-OTHER-FIRMWARE/' "$NVRAM_STATE"
out=$(run discover 2>&1); rc=$?
nonzero "discover: unknown format exits non-zero" "$rc"
has  "discover: unknown format prints the raw value" "$out" "SOMETHING-UNPARSEABLE-FROM-OTHER-FIRMWARE"
has  "discover: unknown format falls back to manual" "$out" "by hand"

# discover --write: opt-in, backs up, and never leaves an unparseable config
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="self"' 'FLEET_ALLOW_PASSWORD=0'
out=$(run --write discover 2>&1)
has  "--write: reports what it wrote"          "$out" "Wrote $FLEETCTL_CONF"
has  "--write: config now holds the fleet"     "$(cat "$FLEETCTL_CONF")" "192.168.1.2,mac=AA:BB:CC:DD:EE:02"
has  "--write: unrelated settings preserved"   "$(cat "$FLEETCTL_CONF")" "FLEET_ALLOW_PASSWORD=0"
is   "--write: previous config kept as .bak"   "$([ -f "$FLEETCTL_CONF.bak" ] && echo y)" "y"
is   "--write: result parses as shell"         "$(sh -n "$FLEETCTL_CONF" 2>&1; echo rc=$?)" "rc=0"

# writing twice must not accumulate duplicate FLEET_NODES lines
run --write discover >/dev/null 2>&1
is   "--write: idempotent, one FLEET_NODES line" "$(grep -c '^FLEET_NODES=' "$FLEETCTL_CONF")" "1"

# without the flag it stays read-only
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="self"' 'FLEET_NODES=""'
run discover >/dev/null 2>&1
has  "discover: writes nothing without --write" "$(cat "$FLEETCTL_CONF")" 'FLEET_NODES=""'
is   "discover: leaves no .bak behind"         "$([ -f "$FLEETCTL_CONF.bak" ] && echo y)" ""

# === self / local target ====================================================
echo "-- self (local execution)"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self"'
out=$(run run 'echo LOCALLY-EXECUTED' 2>&1); rc=$?
has  "self: the command runs on this machine" "$out" "[self] LOCALLY-EXECUTED"
is   "self: no SSH client was involved"       "$([ -s "$TMP/sshlog" ] && echo used)" ""
is   "self: success exits zero"               "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self"'
out=$(run run 'exit 7' 2>&1); rc=$?
has  "self: local exit status is preserved"   "$out" "exit 7"
nonzero "self: local failure => non-zero exit" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self"' 'FLEET_RUN_TIMEOUT=1'
out=$(run run 'sleep 4' 2>&1)
has  "self: the watchdog applies locally too" "$out" "timed out after 1s"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self"'
out=$(run --yes install https://example.invalid/addon.sh 2>&1); rc=$?
has  "self: install runs locally"             "$out" "Installed and HEALING"
is   "self: install needs no mac pin"         "$rc" "0"

# the machine stops looking like an ASUS unit -> mutating verbs must refuse
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self"'
sed -i.bak '/^productid=/d' "$NVRAM_STATE"
out=$(run --yes install https://example.invalid/addon.sh 2>&1); rc=$?
has  "self: refused when this is not an ASUS unit" "$out" "this machine is not an ASUS router"
nonzero "self: non-router refusal exits non-zero" "$rc"
out=$(run run 'echo STILL-FINE' 2>&1)
has  "self: 'run' still works off-router"     "$out" "[self] STILL-FINE"

# installing fleetctl onto itself would rewrite the running script
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self 192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --yes install https://example.invalid/asuswrt-merlin-fleetctl/main/install.sh 2>&1); rc=$?
has  "self: refuses to install fleetctl over itself" "$out" "installing over a running script is undefined"
has  "self: points at 'update' instead"       "$out" "fleetctl update"
nonzero "self: self-install refusal exits non-zero" "$rc"

# an explicit `self` is opt-in, so --include-self must not be needed for it
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="self"'
out=$(run run 'echo NO-FLAG-NEEDED' 2>&1)
hasnt "self: not subject to the self-exclusion guard" "$out" "controller itself"
has  "self: runs without --include-self"      "$out" "NO-FLAG-NEEDED"

# === workstation ergonomics =================================================
echo "-- workstation"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"' 'FLEET_USER=""'
run run true >/dev/null 2>&1
hasnt "workstation: no user is forced onto the target" "$(cat "$TMP/sshlog")" "@192.168.1.2"
has  "workstation: bare host lets ~/.ssh/config decide" "$(cat "$TMP/sshlog")" " 192.168.1.2 "

reset; conf 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"' "FLEET_KEY=\"$TMP/absent.key\""
out=$(run health 2>&1); rc=$?
has  "workstation: a missing key is not a failure" "$out" "credentials your SSH client already has"
is   "workstation: health still passes"       "$rc" "0"

# a unit that falls back to asking for a password must be diagnosed, not echoed
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.7"'
host_fixture 192.168.1.7 prompt "" "" no "" 0 0
out=$(run nodes 2>&1)
has  "password prompt: diagnosed as missing credentials" "$out" "no usable credentials"
has  "password prompt: says how to fix it"      "$out" "FLEET_KEY"
hasnt "password prompt: does not echo the prompt back" "$out" "'s password:"

# dbclient with BatchMode phrases the SAME condition differently — one diagnosis
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.8"'
host_fixture 192.168.1.8 noauth "" "" no "" 0 0
out=$(run nodes 2>&1)
has  "no-auth-methods: same diagnosis as a prompt" "$out" "no usable credentials"
has  "no-auth-methods: points at the mesh-wide fix" "$out" "propagates it to every node"
hasnt "no-auth-methods: not misreported as unreachable" "$out" "unreachable"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
run nodes >/dev/null 2>&1
has  "batchmode: dbclient told never to prompt" "$(cat "$TMP/sshlog")" "BatchMode=yes"

# === node specs =============================================================
echo "-- node specs"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="admin2@192.168.1.2:2222,mac=AA:BB:CC:DD:EE:02,name=alpha"'
out=$(run run true 2>&1)
has  "spec: custom port reaches dbclient"     "$(cat "$TMP/sshlog")" "-p 2222"
has  "spec: custom user reaches dbclient"     "$(cat "$TMP/sshlog")" "admin2@192.168.1.2"
has  "spec: name= is used as the label"       "$out" "alpha"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02,bogus=1"'
out=$(run run true 2>&1)
has  "spec: unknown field warns"              "$out" "ignoring unknown field"
has  "spec: unknown field is not fatal"       "$out" "1 ok"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,auth=pass"' 'FLEET_ALLOW_PASSWORD=0'
out=$(run run true 2>&1); rc=$?
has  "spec: auth=pass with password off is refused" "$out" "FLEET_ALLOW_PASSWORD=0"
nonzero "spec: auth=pass refusal exits non-zero" "$rc"

# === nodes ==================================================================
echo "-- nodes"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02 192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run nodes 2>&1); rc=$?
has  "nodes: Merlin node reported eligible"   "$out" "merlin: yes"
has  "nodes: stock node reported run-only"    "$out" "run only"
has  "nodes: pins verified"                   "$out" "pin ok"
is   "nodes: all-good exits zero"             "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:99"'
out=$(run nodes 2>&1); rc=$?
has  "nodes: wrong pin is reported"           "$out" "PIN MISMATCH"
nonzero "nodes: wrong pin exits non-zero"     "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.5"'
out=$(run nodes 2>&1)
has  "nodes: changed host key is called out"  "$out" "HOST KEY MISMATCH"
has  "nodes: changed host key explains both causes" "$out" "reflash"

# === run ====================================================================
echo "-- run"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2 192.168.1.3"'
out=$(run run uptime 2>&1); rc=$?
has  "run: output prefixed per node (a)"      "$out" "[192.168.1.2] output-from-192.168.1.2"
has  "run: output prefixed per node (b)"      "$out" "[192.168.1.3] output-from-192.168.1.3"
has  "run: summary counts both"               "$out" "(2 ok, 0 failed, 0 skipped)"
is   "run: all-good exits zero"               "$rc" "0"
has  "run: stock node is a valid run target"  "$out" "output-from-192.168.1.3"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.9 192.168.1.2"'
out=$(run run uptime 2>&1); rc=$?
has  "run: continues past an unreachable node" "$out" "output-from-192.168.1.2"
has  "run: failed node is listed FAIL"        "$out" "FAIL     192.168.1.9"
has  "run: mixed result counted"              "$out" "(1 ok, 1 failed, 0 skipped)"
nonzero "run: any failure => non-zero exit"   "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
host_fixture 192.168.1.2 ok RT-NODE-A 1 yes "AA:BB:CC:DD:EE:02," 3 0
out=$(run run 'false' 2>&1); rc=$?
has  "run: remote failure lands in the summary" "$out" "FAIL     192.168.1.2"
has  "run: remote exit code is preserved"     "$out" "exit 3"
nonzero "run: remote failure => non-zero exit" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"' 'FLEET_RUN_TIMEOUT=1'
host_fixture 192.168.1.2 ok RT-NODE-A 1 yes "AA:BB:CC:DD:EE:02," 0 4
out=$(run run 'sleep 4' 2>&1); rc=$?
has  "run: a hung node times out"             "$out" "timed out after 1s"
nonzero "run: timeout => non-zero exit"       "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.1,mac=AA:BB:CC:DD:EE:01"'
out=$(run run uptime 2>&1); rc=$?
has  "run: controller excluded by default"    "$out" "this is the controller itself"
is   "run: self-skip is SKIPPED, not FAIL"    "$rc" "0"
out=$(run --include-self run uptime 2>&1)
has  "run: --include-self includes it"        "$out" "output-from-192.168.1.1"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2 192.168.1.3"'
out=$(run --dry-run run 'rm -rf /' 2>&1); rc=$?
has  "dry-run: announces itself"              "$out" "DRY RUN"
has  "dry-run: shows what would run"          "$out" "would run: rm -rf /"
hasnt "dry-run: executes nothing"             "$out" "output-from-192.168.1.2"
is   "dry-run: exits zero"                    "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(run run uptime 2>&1); rc=$?
nonzero "run: empty fleet exits non-zero"     "$rc"
has  "run: empty fleet points at discover"    "$out" "fleetctl discover"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(run --nodes "192.168.1.2" run uptime 2>&1)
has  "--nodes: overrides an empty conf"       "$out" "output-from-192.168.1.2"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
mkdir -p "$FLEETCTL_LOCK"; echo $$ > "$FLEETCTL_LOCK/pid"
out=$(run run uptime 2>&1); rc=$?
has  "lock: refuses a concurrent fan-out"     "$out" "another fleetctl is already running"
nonzero "lock: concurrent fan-out exits non-zero" "$rc"
rm -rf "$FLEETCTL_LOCK"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
mkdir -p "$FLEETCTL_LOCK"; echo 999999 > "$FLEETCTL_LOCK/pid"
out=$(run run uptime 2>&1)
has  "lock: reclaims a stale lock"            "$out" "output-from-192.168.1.2"

# === install ================================================================
echo "-- install"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --yes install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: surfaces the installer's own output" "$out" "Installed and HEALING"
has  "install: warns that exit 0 can still be inert" "$out" "inert configuration"
is   "install: success exits zero"            "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
run --yes install https://example.invalid/install.sh uninstall >/dev/null 2>&1
has  "install: passes args through (rollback path)" "$(cat "$TMP/installcmd-192.168.1.2")" "uninstall"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
out=$(run --yes install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: refuses an unpinned node"      "$out" "no MAC pin"
nonzero "install: unpinned refusal exits non-zero" "$rc"
out=$(run --yes --allow-unpinned install https://example.invalid/install.sh 2>&1)
has  "install: --allow-unpinned overrides"    "$out" "Installed and HEALING"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:99"'
out=$(run --yes install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: refuses a pin mismatch"        "$out" "does not match"
has  "install: pin mismatch suggests re-discovery" "$out" "fleetctl discover"
nonzero "install: pin mismatch exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run --yes install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: skips an ineligible node"      "$out" "not Merlin-eligible"
has  "install: ineligible is SKIPPED not FAIL" "$out" "SKIPPED  192.168.1.3"
is   "install: a skip alone is not a failure" "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
host_fixture 192.168.1.2 ok RT-NODE-A 1 yes "AA:BB:CC:DD:EE:02," 90 0
out=$(run --yes install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: download failure is distinguished" "$out" "could not download the installer"
nonzero "install: download failure exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --yes install ftp://example.invalid/install.sh 2>&1); rc=$?
has  "install: rejects a non-http URL"        "$out" "must be an http(s) URL"
nonzero "install: bad URL exits non-zero"     "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --dry-run install https://example.invalid/install.sh 2>&1)
has  "install --dry-run: shows the command"   "$out" "would run: curl -fsSL"
hasnt "install --dry-run: installs nothing"   "$out" "Installed and HEALING"

# === push ===================================================================
echo "-- push"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
echo "PAYLOAD-CONTENT" > "$TMP/payload"
out=$(run --yes push "$TMP/payload" /jffs/scripts/payload 2>&1); rc=$?
is   "push: content lands on the node"        "$(cat "$TMP/pushed-192.168.1.2" 2>/dev/null)" "PAYLOAD-CONTENT"
has  "push: reports the destination"          "$out" "wrote /jffs/scripts/payload"
is   "push: success exits zero"               "$rc" "0"
has  "push: writes atomically via temp+mv"    "$(cat "$TMP/sshlog")" ".fleetctl."

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --yes push "$TMP/payload" relative/path 2>&1); rc=$?
has  "push: refuses a relative destination"   "$out" "must be absolute"
nonzero "push: relative destination exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --yes push "$TMP/does-not-exist" /jffs/scripts/x 2>&1); rc=$?
has  "push: refuses a missing local file"     "$out" "no such file"
nonzero "push: missing local file exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run --yes push "$TMP/payload" /jffs/scripts/payload 2>&1)
has  "push: skips an ineligible node"         "$out" "not Merlin-eligible"
is   "push: nothing written to a skipped node" "$([ -f "$TMP/pushed-192.168.1.3" ] && echo y)" ""

# === production safety: consent before changing a unit ======================
echo "-- consent gate"
# These are production routers, often the only one the owner has. `install` runs
# someone else's code as root; `push` overwrites files. Unattended, both must
# refuse rather than assume.
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run install https://example.invalid/addon.sh 2>&1); rc=$?
has  "consent: unattended install is refused"   "$out" "refusing to fan out unattended"
has  "consent: names the escape hatch"          "$out" "--yes"
has  "consent: suggests previewing first"       "$out" "--dry-run"
hasnt "consent: nothing was installed"          "$out" "Installed and HEALING"
nonzero "consent: refusal exits non-zero"       "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --yes install https://example.invalid/addon.sh 2>&1)
has  "consent: --yes states the plan"           "$out" "About to download and RUN this installer as root"
has  "consent: --yes proceeds"                  "$out" "Installed and HEALING"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
echo "PAYLOAD-CONTENT" > "$TMP/payload"
out=$(run push "$TMP/payload" /jffs/scripts/payload 2>&1); rc=$?
has  "consent: unattended push is refused"      "$out" "refusing to fan out unattended"
is   "consent: nothing was written"             "$([ -f "$TMP/pushed-192.168.1.2" ] && echo y)" ""
nonzero "consent: push refusal exits non-zero"  "$rc"

# a dry run changes nothing, so it must never demand consent
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --dry-run install https://example.invalid/addon.sh 2>&1); rc=$?
hasnt "consent: dry run needs no --yes"         "$out" "refusing to fan out"
is   "consent: dry run exits zero"              "$rc" "0"

# `run` is deliberately NOT gated — reflexive y-pressing devalues real prompts
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
out=$(run run uptime 2>&1); rc=$?
hasnt "consent: 'run' is not gated"             "$out" "refusing to fan out"
is   "consent: 'run' still works unattended"    "$rc" "0"

# a prod operator needs to know whether a push replaces something
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run --dry-run push "$TMP/payload" /jffs/scripts/payload 2>&1)
has  "dry-run push: distinguishes create/overwrite" "$out" "would "

# === consumer integration (addons depending on fleetctl) ====================
echo "-- consumer integration"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2 192.168.1.9"'
out=$(run --porcelain run uptime 2>&1); rc=$?
has  "porcelain: stable tab-separated OK row"   "$out" "$(printf 'fleetctl\t192.168.1.2\tOK')"
has  "porcelain: stable tab-separated FAIL row" "$out" "$(printf 'fleetctl\t192.168.1.9\tFAIL')"
hasnt "porcelain: no decorative summary box"    "$out" "--- summary ---"
nonzero "porcelain: exit code still reflects failure" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run --yes --porcelain install https://example.invalid/addon.sh 2>&1)
has  "porcelain: SKIPPED is machine-readable"   "$out" "$(printf 'fleetctl\t192.168.1.3\tSKIPPED')"

# `nodes` is the fleet-state query a consumer most wants to parse
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02 192.168.1.3,mac=AA:BB:CC:DD:EE:03 192.168.1.9"'
out=$(run --porcelain nodes 2>&1); rc=$?
has  "porcelain nodes: eligible row"            "$out" "$(printf 'fleetctl-node\t192.168.1.2\treachable\tRT-NODE-A\teligible\tpin-ok')"
has  "porcelain nodes: ineligible row"          "$out" "$(printf 'fleetctl-node\t192.168.1.3\treachable\tRP-NODE-B\tineligible')"
has  "porcelain nodes: unreachable row"         "$out" "$(printf 'fleetctl-node\t192.168.1.9\tunreachable')"
hasnt "porcelain nodes: no human header"        "$out" "configured nodes"
nonzero "porcelain nodes: exit code preserved"  "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(FLEETCTL_LIB=1 "$SH" -c '. "$1"; fleet_spec 192.168.1.2,mac=AA:BB:CC:DD:EE:02,name=alpha; echo "$SPEC_NAME/$SPEC_MAC"; fleet_version' _ "$FLEETCTL" 2>&1)
has  "lib mode: sourcing exposes fleet_spec"    "$out" "alpha/AA:BB:CC:DD:EE:02"
VER=$(awk -F= '/^VERSION=/{print $2; exit}' "$FLEETCTL")
has  "lib mode: fleet_version reports the script version" "$out" "$VER"
env_out=$(FLEETCTL_LIB=1 "$SH" "$FLEETCTL" run 'echo SHOULD-NOT-RUN' 2>&1)
hasnt "lib mode: loading never executes a verb" "$env_out" "SHOULD-NOT-RUN"

# === eligibility diagnosis ==================================================
echo "-- eligibility diagnosis"
# jffs2_scripts is MERLIN-ONLY: absent on stock firmware, not "0". The two cases
# need different advice — one is a firmware flash, the other is a GUI toggle.
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run --yes install https://example.invalid/addon.sh 2>&1)
has  "stock node: diagnosed as not-Merlin"     "$out" "is not running Asuswrt-Merlin"
has  "stock node: warns a build may not exist" "$out" "no Merlin build"
hasnt "stock node: does NOT suggest a GUI toggle it lacks" "$out" "Enable JFFS custom scripts and configs"

# Merlin with the setting off -> that IS the GUI toggle case
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
host_fixture 192.168.1.3 ok RT-NODE-C 0 no "AA:BB:CC:DD:EE:03," 0 0
out=$(run --yes install https://example.invalid/addon.sh 2>&1)
has  "scripts-off node: points at the GUI toggle" "$out" "Enable JFFS custom scripts and configs"
hasnt "scripts-off node: not called non-Merlin" "$out" "is not running Asuswrt-Merlin"

# Merlin, scripts on, but the directory is missing -> a third, distinct case
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
host_fixture 192.168.1.3 ok RT-NODE-D 1 no "AA:BB:CC:DD:EE:03," 0 0
out=$(run --yes install https://example.invalid/addon.sh 2>&1)
has  "no-scripts-dir node: reported distinctly" "$out" "but no"

# === single-device / passthrough ============================================
echo "-- single device"
# A fleet of one is the common case for a consuming addon's user. On a router,
# an unconfigured fleet must act on THIS unit rather than erroring.
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(runp router run 'echo SINGLE-DEVICE' 2>&1); rc=$?
has  "single: unconfigured fleet acts on this unit" "$out" "SINGLE-DEVICE"
has  "single: says so loudly"                  "$out" "single-device mode"
is   "single: exits zero"                      "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(runp router --yes install https://example.invalid/addon.sh 2>&1); rc=$?
has  "single: install works with no config"    "$out" "Installed and HEALING"
is   "single: install exits zero"              "$rc" "0"

# the note must not pollute a parser's stdout
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(runp router --porcelain run 'echo X' 2>/dev/null)
hasnt "single: note goes to stderr, not porcelain stdout" "$out" "single-device mode"
has  "single: porcelain row still emitted"     "$out" "$(printf 'fleetctl\tself\tOK')"

# off-router there is nothing to fall back to
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(run run 'echo X' 2>&1); rc=$?
has  "single: workstation with no fleet still errors" "$out" "not a router"
nonzero "single: workstation empty fleet exits non-zero" "$rc"

# a lone router reports no device list — that must read as "no mesh", not "broken"
reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_CONTROLLER="self"'
sed -i.bak '/^cfg_device_list=/d' "$NVRAM_STATE"
out=$(runp router discover 2>&1)
has  "single: no mesh is explained as normal"  "$out" "no mesh here"
has  "single: suggests the zero-config answer" "$out" "acts on this unit when no fleet is set"

# === controller auto-detection ==============================================
echo "-- controller auto-detection"
# workstation, nothing configured: find the router via the default gateway
cat > "$BIN/route" <<'M'
#!/bin/sh
case "$*" in *"get default"*) echo "   gateway: 192.168.1.1";; esac
M
chmod +x "$BIN/route"
reset; withkey; conf "FLEET_KEY=\"$KEY\""
out=$(run discover 2>&1); rc=$?
has  "auto: checks the default gateway"        "$out" "checking the default gateway (192.168.1.1)"
has  "auto: confirms what it found"            "$out" "Found an ASUS unit there"
has  "auto: proceeds to list nodes"            "$out" "192.168.1.2"
is   "auto: succeeds with zero config"         "$rc" "0"

# gateway that is not an ASUS unit must not be assumed usable
reset; withkey; conf "FLEET_KEY=\"$KEY\""
host_fixture 192.168.1.1 ok "" "" no "" 0 0
out=$(run discover 2>&1); rc=$?
has  "auto: refuses a non-ASUS gateway"        "$out" "did not identify as an ASUS unit"
has  "auto: tells the user how to set it"      "$out" "FLEET_CONTROLLER="
nonzero "auto: non-ASUS gateway exits non-zero" "$rc"

# unreachable gateway: report the auth/reachability reason, do not guess on
reset; withkey; conf "FLEET_KEY=\"$KEY\""
host_fixture 192.168.1.1 deny "" "" no "" 0 0
out=$(run discover 2>&1); rc=$?
has  "auto: surfaces the SSH failure reason"   "$out" "no usable credentials"
nonzero "auto: unreachable gateway exits non-zero" "$rc"
rm -f "$BIN/route"

# no route tool at all -> fall back to explicit config, never a wild guess
reset; withkey; conf "FLEET_KEY=\"$KEY\""
out=$(PATH="$BIN" run discover 2>&1); rc=$?
nonzero "auto: no route tool exits non-zero"   "$rc"

# === health =================================================================
echo "-- health"
# On the ROUTER a missing key IS a failure — there is no ~/.ssh to fall back on.
# FLEETCTL_PLATFORM forces the branch so both platforms stay covered.
reset; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(runp router health 2>&1); rc=$?
has  "health: a missing key is reported, not judged" "$out" "no key at"
has  "health: defers the verdict to reachability" "$out" "the real test"
is   "health: missing key alone is not a failure" "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(runp router health 2>&1)
has  "health (router): checks jffs2_scripts"  "$out" "JFFS custom scripts enabled"
has  "health (router): names the unit"        "$out" "running on the router"
out=$(run health 2>&1)
has  "health (workstation): says so"          "$out" "running on a workstation"
hasnt "health (workstation): no local jffs2_scripts check" "$out" "JFFS custom scripts"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run health 2>&1); rc=$?
has  "health: reports the node eligible"      "$out" "Merlin-eligible"
has  "health: reports the SSH client"         "$out" "SSH client: dbclient"
is   "health: healthy exits zero"             "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
out=$(run health 2>&1)
has  "health: warns about a missing pin"      "$out" "no mac= pin"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run health 2>&1)
has  "health: ineligible node gets an actionable reason" "$out" "is not running Asuswrt-Merlin"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.4"'
out=$(run health 2>&1); rc=$?
has  "health: auth failure names the cause"   "$out" "no usable credentials"
nonzero "health: unreachable node => non-zero exit" "$rc"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
