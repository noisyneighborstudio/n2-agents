#!/bin/sh
# A stand-in agent for the loop tests, installed as `codex`. It answers by
# role — the ROLE line of the prompt on stdin — and misbehaves on cue:
# files in $LOOP_FAKE (the scenario dir) switch each misbehaviour on.
#   quota-<profile>   that slot is out of quota
#   worker-quota-<profile>   holds n: that slot's next n worker turns hit a
#                     limit that resets in two seconds
#   slow              workers take a minute (time to pause them)
#   fail-b-once       the first verification rejects criterion has-b
#   liar              the sign-off says done whatever the evidence says
set -eu
if [ "${LOOP_FAKE_STRUCTURED:-}" = 1 ]; then
  exec /usr/bin/python3 "$(dirname "$0")/fake-loop-protocol.py" "$0" "$@"
fi
prompt=$(cat)
role=$(printf '%s\n' "$prompt" | sed -n 's/^ROLE: //p' | head -1)
chunk=$(printf '%s\n' "$prompt" | sed -n 's/^CHUNK: //p' | head -1)
profile=$(basename "$(dirname "$CODEX_HOME")")
echo "$role ${chunk:-} $profile" >> "$LOOP_FAKE/calls"

# A shared budget removes dependence on how the scheduler allocates slots.
# Lock both shared and legacy counters because a slot can run parallel turns.
if [ "$role" = worker ]; then
  left=$(/usr/bin/python3 - "$LOOP_FAKE" "$profile" <<'COUNTER'
import fcntl,sys
from pathlib import Path
root=Path(sys.argv[1]);path=root/'worker-quota-total'
if not path.exists():path=root/('worker-quota-'+sys.argv[2])
if not path.exists():print(0)
else:
    with path.open('r+') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        left=int(stream.read());print(left)
        stream.seek(0);stream.write(str(max(0,left-1)));stream.truncate()
COUNTER
)
  if [ "$left" -gt 0 ]; then
    retry=$(cat "$LOOP_FAKE/worker-retry-seconds" 2>/dev/null || echo 2)
    echo "ERROR: You've hit your usage limit. Try again in $retry seconds." >&2
    exit 1
  fi
fi

if [ -f "$LOOP_FAKE/quota-$profile" ]; then
  echo "ERROR: You've hit your usage limit. Try again at Sep 26th, 2099 11:20 AM." >&2
  exit 1
fi

case $role in
  planner)
    cat <<'JSON'
Planned.
N2_RESULT {"plan":{"goal":"Write a.txt and b.txt","criteria":[{"id":"has-a","description":"a.txt exists","verification":"look for a.txt"},{"id":"has-b","description":"b.txt says done","verification":"read b.txt"}],"verificationCommands":["test -f a.txt","grep -q done b.txt"],"chunks":[{"id":"a","title":"Write a","instructions":"Create a.txt","paths":["a.txt"],"criteria":["has-a"],"dependsOn":[],"effort":"light"},{"id":"b","title":"Write b","instructions":"Create b.txt","paths":["b.txt"],"criteria":["has-b"],"dependsOn":[],"effort":"deep"}]},"questions":[]}
JSON
    ;;
  worker)
    [ -f "$LOOP_FAKE/slow" ] && sleep 60
    n=$(( $(cat "$LOOP_FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LOOP_FAKE/n"
    echo "done by $profile, turn $n" > "$chunk.txt"
    echo "N2_RESULT {\"status\":\"done\",\"summary\":\"wrote $chunk.txt\"}"
    ;;
  supervisor)
    case $prompt in
      *"Review one chunk"*) echo 'N2_RESULT {"decision":"accept","summary":"looks right"}' ;;
      *"answer for the result"*)
        if [ -f "$LOOP_FAKE/liar" ] || [ "${prompt#*does NOT hold}" = "$prompt" ]; then
          echo 'N2_RESULT {"decision":"done","summary":"all verified"}'
        else
          echo 'N2_RESULT {"decision":"repair","summary":"b is wrong","reopen":[{"chunk":"b","feedback":"b.txt must say done"}]}'
        fi ;;
      *) echo 'N2_RESULT {"decision":"pause","question":"unexpected"}' ;;
    esac
    ;;
  verifier)
    b=true
    if [ -f "$LOOP_FAKE/fail-b-once" ]; then b=false; rm "$LOOP_FAKE/fail-b-once"; fi
    echo "N2_RESULT {\"criteria\":[{\"id\":\"has-a\",\"passed\":true,\"evidence\":\"a.txt present\"},{\"id\":\"has-b\",\"passed\":$b,\"evidence\":\"b.txt checked\"}],\"summary\":\"checked\"}"
    ;;
  *) echo "unknown role" >&2; exit 2 ;;
esac
