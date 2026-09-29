#!/bin/sh
# Worker tasks run in the login session. A request handled outside it (over
# ssh, where the login keychain is locked) is handed to launchd's gui domain,
# and refused when nobody is logged in. launchctl is a fixture: it answers the
# session the test names and starts a bootstrapped job the way launchd does,
# from its plist and with only the environment the plist declares.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2session.XXXXXX")
trap 'rm -rf "$base"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "want '$2' in '$3'" ;; esac; }
refute(){ case $3 in *"$2"*) bad "$1" "did not want '$2' in '$3'" ;; *) ok "$1" ;; esac; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$2', got '$3'"; fi; }

mkdir -p "$base/bin"
printf '#!/bin/sh\nexit 0\n' > "$base/bin/cursor-agent"
printf '#!/bin/sh\nexit 1\n' > "$base/bin/security"
cat > "$base/bin/launchctl" <<'FAKE'
#!/usr/bin/python3
import os, plistlib, subprocess, sys
with open(os.environ['LC_LOG'], 'a') as log: log.write(' '.join(sys.argv[1:]) + '\n')
verb = sys.argv[1] if len(sys.argv) > 1 else ''
if verb == 'managername': print(os.environ['LC_SESSION']); sys.exit(0)
if verb == 'bootstrap':
    if os.environ.get('LC_REFUSE'): sys.exit(5)
    with open(sys.argv[3], 'rb') as f: job = plistlib.load(f)
    out = open(job['StandardOutPath'], 'a')
    subprocess.Popen(job['ProgramArguments'], env=job['EnvironmentVariables'], cwd='/',
                     stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    sys.exit(0)
if verb == 'bootout': sys.exit(0)
sys.exit(64)
FAKE
chmod +x "$base/bin/cursor-agent" "$base/bin/security" "$base/bin/launchctl"
export PATH="$base/bin:$PATH"
lclog=$base/lc.log; : > "$lclog"

peer() { h=$1; shift; env HOME="$base/$h" N2_FLEET_AGENTS="$repo/agents" \
           N2_FLEET_LAUNCHCTL="$base/bin/launchctl" LC_LOG="$lclog" \
           LC_SESSION="${session:-Aqua}" LC_REFUSE="${refuse:-}" "$repo/agents" "$@"; }
await_state() {  # <peer> <id> <state>
  as_end=$(( $(date +%s) + 25 ))
  while [ "$(date +%s)" -lt "$as_end" ]; do
    as_s=$(peer "$1" fleet task show "$2" 2>/dev/null | awk -F'\t' '$1=="state"{print $2}')
    case $as_s in completed|failed) echo "$as_s"; return 0 ;; esac
    sleep 1
  done
  echo "${as_s:-<none>}"
}
dispatch() { peer alpha fleet task run --machine beta --agent cursor --allow-unknown-auth "$@" 2>&1; }

for h in alpha beta; do mkdir -p "$base/$h"; done
peer alpha fleet init --machine alpha >/dev/null
B=$(peer beta fleet init --machine beta | awk '{print $2}')
peer beta fleet pair --home "$base/alpha" --code "$(peer alpha fleet invite --peer "$B" 2>/dev/null)" >/dev/null 2>&1
db=$base/beta/.n2-agents/fleet/tasks/db
uid=$(id -u)

# In the login session the worker starts directly; launchd is not involved.
session=Aqua
out=$(dispatch 'echo inline'); T1=$(printf '%s' "$out" | cut -f1)
same "login session: the task completes" completed "$(await_state alpha "$T1")"
same "login session: the command ran" inline "$(cat "$db/$T1/out/stdout" 2>/dev/null)"
refute "login session: nothing is handed to launchd" bootstrap "$(cat "$lclog")"

# Outside it, the worker is a gui-domain job that re-enters through task _run.
session=Background
out=$(dispatch 'echo handed-off'); T2=$(printf '%s' "$out" | cut -f1)
same "background session: the task completes" completed "$(await_state alpha "$T2")"
same "background session: the command ran" handed-off "$(cat "$db/$T2/out/stdout" 2>/dev/null)"
check "background session: the job goes to the gui domain" "bootstrap gui/$uid $db/$T2/worker.plist" "$(cat "$lclog")"
plist=$(cat "$db/$T2/worker.plist" 2>/dev/null)
check "the job re-enters as task _run" "<string>task</string><string>_run</string><string>$T2</string>" "$plist"
check "the job carries the fleet's HOME" "<key>HOME</key><string>$base/beta</string>" "$plist"

# A job runs only a task that was accepted and has not started.
peer beta fleet task _run "$T2" >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok "task _run refuses a finished task"; else bad "task _run refuses a finished task" "rc=0"; fi

# With nobody logged in the task is refused, not started where it cannot sign in.
refuse=1
out=$(dispatch 'echo never'); rc=$?; T3=$(printf '%s' "$out" | cut -f1)
if [ "$rc" != 0 ]; then ok "no login session: the dispatch fails"; else bad "no login session: the dispatch fails" "$out"; fi
check "no login session: the dispatcher says why" "no one is logged in there" "$out"
refute "no login session: it is not called uncertain" "uncertain" "$out"
check "no login session: the worker records the refusal" "no one is logged in" "$(peer beta fleet task show "$T3" 2>&1)"
same "no login session: the command never ran" "" "$(cat "$db/$T3/out/stdout" 2>/dev/null)"

# Starting another task unloads the finished task's job.
check "a finished task's job is booted out" "bootout gui/$uid/com.n2agents.fleet-task.$T2" "$(cat "$lclog")"
if [ -f "$db/$T2/worker.plist" ]; then bad "the finished job's plist is removed" "still present"
else ok "the finished job's plist is removed"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
