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
auth=ok; model=""; jffs=""; dir=no; macs=""; rc=0; sleepsec=0
. "$f"
[ "$sleepsec" != "0" ] && sleep "$sleepsec"
case "$auth" in
  ok) : ;;
  hostkey) echo "Host key mismatch for $host !" >&2; exit 255 ;;
  *) echo "dbclient: Authentication failed" >&2; exit 255 ;;
esac
case "$cmd" in
  *__fleetprobe__*) echo "__fleetprobe__ v=1 model=$model jffs=$jffs dir=$dir macs=$macs"; exit 0 ;;
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
reset() {
  printf '%s\n' \
    'http_username=admin' 'sshd_port=22' 'jffs2_scripts=1' \
    'productid=RT-PLACEHOLDER' 'lan_ipaddr=192.168.1.1' 'lan_hwaddr=AA:BB:CC:DD:EE:01' \
    'label_mac=AA:BB:CC:DD:EE:01' \
    'cfg_device_list=<controller>192.168.1.1>AA:BB:CC:DD:EE:01>1<node1>192.168.1.2>AA:BB:CC:DD:EE:02>0<node2>192.168.1.3>AA:BB:CC:DD:EE:03>0' \
    > "$NVRAM_STATE"
  rm -rf "$TMP/hosts" "$TMP/home" "$TMP/lock" "$TMP/sshlog" "$TMP"/pushed-* "$TMP"/installcmd-*
  rm -f "$TMP/fleetctl.key" "$TMP/fleetctl.key.pub"   # tests opt in via withkey
  mkdir -p "$TMP/hosts"
  #            host          auth  model        jffs dir macs                     rc sleep
  host_fixture 192.168.1.1   ok    RT-PLACEHDR  1    yes "AA:BB:CC:DD:EE:01,"     0  0   # controller (self)
  host_fixture 192.168.1.2   ok    RT-NODE-A    1    yes "AA:BB:CC:DD:EE:02,"     0  0   # Merlin node
  host_fixture 192.168.1.3   ok    RP-NODE-B    ""   no  "AA:BB:CC:DD:EE:03,"     0  0   # stock node
  host_fixture 192.168.1.4   deny  ""           ""   no  ""                       0  0   # auth fails
  host_fixture 192.168.1.5   hostkey ""         ""   no  ""                       0  0   # host key changed
  : > "$FLEETCTL_CONF"
}
conf() { printf '%s\n' "$@" > "$FLEETCTL_CONF"; }
KEY="$TMP/fleetctl.key"
withkey() { echo "MOCK-PRIVATE-KEY" > "$KEY"; chmod 600 "$KEY"; }

# --- harness ----------------------------------------------------------------
PASS=0; FAIL=0
run() { "$SH" "$FLEETCTL" "$@"; }
has()   { case "$2" in *"$3"*) PASS=$((PASS+1)); printf '  ok   %s\n' "$1";; *) FAIL=$((FAIL+1)); printf '  FAIL %s\n       got: %s\n' "$1" "$(echo "$2" | tr '\n' '|' | cut -c1-300)";; esac; }
hasnt() { case "$2" in *"$3"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n       unexpectedly got: %s\n' "$1" "$(echo "$2" | tr '\n' '|' | cut -c1-300)";; *) PASS=$((PASS+1)); printf '  ok   %s\n' "$1";; esac; }
is()    { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s | got "%s" want "%s"\n' "$1" "$2" "$3"; fi; }
nonzero(){ if [ "$2" != "0" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s | expected non-zero exit\n' "$1"; fi; }

echo "fleetctl tests ($SH):"

# === setup ==================================================================
echo "-- setup"
reset; conf "FLEET_KEY=\"$KEY\""
out=$(run setup 2>&1)
has  "setup: prints the pubkey line"          "$out" "ssh-ed25519 AAAA"
is   "setup: key file created"                "$([ -f "$KEY" ] && echo y)" "y"
has  "setup: tells the user where to paste"   "$out" "SSH Authentication key"
has  "setup: says AiMesh syncs it"            "$out" "AiMesh syncs that field"
echo "SENTINEL" > "$KEY"
out=$(run setup 2>&1)
has  "setup: refuses to clobber an existing key" "$out" "Key already exists"
is   "setup: existing key untouched"          "$(cat "$KEY")" "SENTINEL"
out=$(run setup --force 2>&1)
has  "setup --force: warns the old key stays authorized" "$out" "OLD public key stays authorized"
is   "setup --force: key replaced"            "$(cat "$KEY")" "MOCK-PRIVATE-KEY"

# === discover ===============================================================
echo "-- discover"
reset; withkey; conf "FLEET_KEY=\"$KEY\""
out=$(run discover 2>&1)
has  "discover: finds node1"                  "$out" "192.168.1.2"
has  "discover: finds node2"                  "$out" "192.168.1.3"
hasnt "discover: excludes the controller (role 1)" "$out" "192.168.1.1"
has  "discover: suggests a FLEET_NODES line"  "$out" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02'
has  "discover: pins MACs in the suggestion"  "$out" "mac=AA:BB:CC:DD:EE:03"
has  "discover: labels the Merlin node"       "$out" "merlin: yes"
has  "discover: labels the stock node"        "$out" "merlin: no"
has  "discover: explains why pins matter"     "$out" "DHCP moves addresses"

reset; withkey; conf "FLEET_KEY=\"$KEY\""
nvram set cfg_device_list= 2>/dev/null; printf 'cfg_device_list=\n' >> "$NVRAM_STATE"
sed -i.bak '/^cfg_device_list=</d' "$NVRAM_STATE"
out=$(run discover 2>&1); rc=$?
nonzero "discover: empty list exits non-zero" "$rc"
has  "discover: empty list explains manual config" "$out" 'FLEET_NODES="192.168.1.2 192.168.1.3"'

reset; withkey; conf "FLEET_KEY=\"$KEY\""
sed -i.bak 's/^cfg_device_list=.*/cfg_device_list=SOMETHING-UNPARSEABLE-FROM-OTHER-FIRMWARE/' "$NVRAM_STATE"
out=$(run discover 2>&1); rc=$?
nonzero "discover: unknown format exits non-zero" "$rc"
has  "discover: unknown format prints the raw value" "$out" "SOMETHING-UNPARSEABLE-FROM-OTHER-FIRMWARE"
has  "discover: unknown format falls back to manual" "$out" "by hand"

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
out=$(run install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: surfaces the installer's own output" "$out" "Installed and HEALING"
has  "install: warns that exit 0 can still be inert" "$out" "inert configuration"
is   "install: success exits zero"            "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
run install https://example.invalid/install.sh uninstall >/dev/null 2>&1
has  "install: passes args through (rollback path)" "$(cat "$TMP/installcmd-192.168.1.2")" "uninstall"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2"'
out=$(run install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: refuses an unpinned node"      "$out" "no MAC pin"
nonzero "install: unpinned refusal exits non-zero" "$rc"
out=$(run --allow-unpinned install https://example.invalid/install.sh 2>&1)
has  "install: --allow-unpinned overrides"    "$out" "Installed and HEALING"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:99"'
out=$(run install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: refuses a pin mismatch"        "$out" "does not match"
has  "install: pin mismatch suggests re-discovery" "$out" "fleetctl discover"
nonzero "install: pin mismatch exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: skips an ineligible node"      "$out" "not Merlin-eligible"
has  "install: ineligible is SKIPPED not FAIL" "$out" "SKIPPED  192.168.1.3"
is   "install: a skip alone is not a failure" "$rc" "0"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
host_fixture 192.168.1.2 ok RT-NODE-A 1 yes "AA:BB:CC:DD:EE:02," 90 0
out=$(run install https://example.invalid/install.sh 2>&1); rc=$?
has  "install: download failure is distinguished" "$out" "could not download the installer"
nonzero "install: download failure exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run install ftp://example.invalid/install.sh 2>&1); rc=$?
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
out=$(run push "$TMP/payload" /jffs/scripts/payload 2>&1); rc=$?
is   "push: content lands on the node"        "$(cat "$TMP/pushed-192.168.1.2" 2>/dev/null)" "PAYLOAD-CONTENT"
has  "push: reports the destination"          "$out" "wrote /jffs/scripts/payload"
is   "push: success exits zero"               "$rc" "0"
has  "push: writes atomically via temp+mv"    "$(cat "$TMP/sshlog")" ".fleetctl."

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run push "$TMP/payload" relative/path 2>&1); rc=$?
has  "push: refuses a relative destination"   "$out" "must be absolute"
nonzero "push: relative destination exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.2,mac=AA:BB:CC:DD:EE:02"'
out=$(run push "$TMP/does-not-exist" /jffs/scripts/x 2>&1); rc=$?
has  "push: refuses a missing local file"     "$out" "no such file"
nonzero "push: missing local file exits non-zero" "$rc"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.3,mac=AA:BB:CC:DD:EE:03"'
out=$(run push "$TMP/payload" /jffs/scripts/payload 2>&1)
has  "push: skips an ineligible node"         "$out" "not Merlin-eligible"
is   "push: nothing written to a skipped node" "$([ -f "$TMP/pushed-192.168.1.3" ] && echo y)" ""

# === health =================================================================
echo "-- health"
reset; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES=""'
out=$(run health 2>&1); rc=$?
has  "health: missing key is a FAIL"          "$out" "no key at"
nonzero "health: FAIL => non-zero exit"       "$rc"

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
has  "health: ineligible node gets remediation" "$out" "Enabling JFFS custom scripts on a node"

reset; withkey; conf "FLEET_KEY=\"$KEY\"" 'FLEET_NODES="192.168.1.4"'
out=$(run health 2>&1); rc=$?
has  "health: auth failure names the cause"   "$out" "SSH auth failed"
nonzero "health: unreachable node => non-zero exit" "$rc"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
