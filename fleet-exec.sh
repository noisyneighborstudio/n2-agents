# fleet-exec.sh — dispatch, workspace handoff and task lifecycle.
# Sourced by `agents` after fleet-sync.sh: it extends the peer protocol with
# task verbs and reads the managed-tool manifest that `sync` replicates.
# See "Dispatch, handoff and task lifecycle" in docs/fleet-design.md.
#
# The rules that matter, restated where they are enforced:
#   * `unreachable` is a fact about the link, never about the work — no code
#     path here promotes it to `failed` and none starts a second run from it;
#   * eligibility is a hard filter evaluated before any speed comparison, and
#     a pin does not skip it;
#   * an unknown estimate component is labelled `assumed`, never invented;
#   * no output is copied anywhere on completion — fetch and distribute are
#     both explicit operator verbs.
# POSIX sh.

exec_db()        { echo "$fleet_root/tasks/db"; }
exec_task_dir()  { echo "$(exec_db)/$1"; }
# The liveness record `sync` counts. Its format is fleet-sync's contract:
# one file per running task, naming the owning pid so a dead worker's record
# can be reaped rather than deferring every disruptive update forever.
exec_active_dir(){ sync_tasks_dir; }
exec_tasks_active() { sync_tasks_active; }

FLEET_EXEC_DEFAULT_TASK=${FLEET_EXEC_DEFAULT_TASK:-300}
FLEET_EXEC_DEFAULT_BPS=${FLEET_EXEC_DEFAULT_BPS:-1048576}

exec_init() { mkdir -p "$(exec_db)" "$(exec_active_dir)" "$fleet_root/tasks/stats" 2>/dev/null || true; }
exec_need() {
  fleet_have_identity || fleet_die "no fleet identity yet — run: agents fleet init"
  exec_init
}

# Content-free id: a task id must not leak the request, and two peers must
# never mint the same id for different work.
exec_new_id() { od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }
exec_valid_id() {
  case ${1:-} in
    ''|*[!0-9a-f]*) return 1 ;;
    *) [ "${#1}" -ge 8 ] && [ "${#1}" -le 64 ] ;;
  esac
}

exec_meta()     { fleet_meta "$(exec_task_dir "$1")" "$2"; }
exec_meta_set() { fleet_meta_set "$(exec_task_dir "$1")" "$2" "$3"; }

exec_task_event() {  # <id> <state> [detail]
  et_d=$(exec_task_dir "$1"); [ -d "$et_d" ] || return 0
  printf '%s\t%s\t%s\n' "$(fleet_now)" "$2" "${3:-}" >> "$et_d/events" 2>/dev/null || true
}

# State transitions go through here so the disconnect rule is enforced in one
# place instead of at every call site.
exec_set_state() {  # <id> <state> [detail]
  es_id=$1 es_new=$2 es_det=${3:-}
  es_old=$(exec_meta "$es_id" state 2>/dev/null || echo unknown)
  case "$es_old" in
    completed|failed)
      # A terminal state is the task's own answer. A later `unreachable`
      # observation about the link must never overwrite it.
      [ "$es_new" = unreachable ] && return 0 ;;
  esac
  exec_meta_set "$es_id" state "$es_new"
  exec_task_event "$es_id" "$es_new" "$es_det"
  fleet_event task-state "task=$es_id state=$es_new ${es_det}"
}

# --- capabilities ----------------------------------------------------------
# What a peer reports about itself. Eligibility is decided from THIS, never
# from the dispatcher's guess about what the other machine has.

exec_vendor_auth() {  # <vendor> -> yes|no|unknown
  eva_v=$1
  eva_p=$(active_profile "$eva_v" 2>/dev/null) || eva_p=Default
  eva_slot=$(config_dir "$eva_p" "$eva_v" 2>/dev/null) || eva_slot=
  [ -n "$eva_slot" ] || { echo unknown; return 0; }
  vendor_authed "$eva_v" "$eva_slot" "$eva_p" 2>/dev/null
  case $? in
    0) echo yes ;;
    1) echo no ;;
    *) echo unknown ;;   # vendor adapter has no auth probe — not a claim
  esac
}

exec_stat_file() { echo "$fleet_root/tasks/stats/$1"; }
exec_stat_get() {  # <name> -> value or empty
  esg_f=$(exec_stat_file "$1"); [ -f "$esg_f" ] || return 0
  # Records contain the mean followed by the sample count. Removing all
  # nondigits concatenates those fields and makes more samples look slower.
  # Malformed records stay unknown instead of becoming invented estimates.
  awk 'NR == 1 { if ($1 ~ /^[0-9]+$/ && (NF == 1 ||
      (NF == 2 && $2 ~ /^[0-9]+$/))) print $1; exit }' "$esg_f" 2>/dev/null
}
# Running mean, stored as "<mean> <count>" so one slow run does not erase the
# history and an unknown stays unknown until there is a real sample.
exec_stat_add() {  # <name> <seconds>
  esa_f=$(exec_stat_file "$1"); mkdir -p "$fleet_root/tasks/stats" 2>/dev/null
  esa_s=$(printf '%s' "${2:-0}" | tr -cd '0-9'); [ -n "$esa_s" ] || return 0
  esa_m=0 esa_n=0
  if [ -f "$esa_f" ]; then
    esa_m=$(awk '{print $1+0}' "$esa_f" 2>/dev/null); esa_n=$(awk '{print $2+0}' "$esa_f" 2>/dev/null)
  fi
  esa_n=$(( esa_n + 1 ))
  esa_m=$(( ( esa_m * (esa_n - 1) + esa_s ) / esa_n ))
  printf '%s %s\n' "$esa_m" "$esa_n" > "$esa_f" 2>/dev/null || true
}

# A caller names the tools it will require (one per line, in the request
# payload) because this machine cannot guess them. Each named tool is answered
# from the manifest when it is managed there, and otherwise from a PATH probe:
# a requirement asks whether the tool is USABLE here, not whether the operator
# happened to put it under fleet management.
exec_capabilities_report() {  # [probe-file] -> the capabilities payload
  printf 'machine=%s\n' "$(fleet_self_machine)"
  printf 'peer=%s\n' "$(fleet_self_id)"
  printf 'running=%s\n' "$(exec_tasks_active)"
  ecr_mt=$(exec_stat_get mean_task); printf 'mean_task=%s\n' "${ecr_mt:--}"
  ecr_bps=$(exec_stat_get bps); printf 'bps=%s\n' "${ecr_bps:--}"
  for ecr_v in $N2_VENDORS; do
    ecr_cli=$(vendor_cli "$ecr_v" 2>/dev/null || echo "$ecr_v")
    if command -v "$ecr_cli" >/dev/null 2>&1; then ecr_ins=yes; else ecr_ins=no; fi
    # Auth is only probed for an installed vendor: "not installed" already
    # decides eligibility, and probing would only add a misleading `no`.
    if [ "$ecr_ins" = yes ]; then ecr_auth=$(exec_vendor_auth "$ecr_v"); else ecr_auth=no; fi
    ecr_mv=$(exec_stat_get "vendor.$ecr_v")
    printf 'vendor=%s\tinstalled=%s\tauth=%s\tmean=%s\n' "$ecr_v" "$ecr_ins" "$ecr_auth" "${ecr_mv:--}"
  done
  # Managed tools, plus a PATH probe, because a tool can be present without
  # being managed and a requirement only asks whether it is usable here.
  ecr_probe=${1:-}
  if [ -n "$ecr_probe" ] && [ -f "$ecr_probe" ]; then
    while IFS= read -r ecr_pn; do
      [ -n "$ecr_pn" ] || continue
      case $ecr_pn in *[!A-Za-z0-9._+-]*) continue ;; esac   # a probe name is never a command
      ecr_pst=$(sync_tool_state "$ecr_pn" 2>/dev/null || echo unmanaged)
      if [ "$ecr_pst" = unmanaged ]; then
        command -v "$ecr_pn" >/dev/null 2>&1 && ecr_pst=ok || ecr_pst=absent
      fi
      printf 'probe=%s\tstate=%s\n' "$ecr_pn" "$ecr_pst"
    done < "$ecr_probe"
  fi
  ecr_f=$(sync_tools_manifest)
  if [ -f "$ecr_f" ]; then
    while IFS= read -r ecr_l; do
      case $ecr_l in ''|'#'*) continue ;; esac
      sync_tool_line_ok "$ecr_l" || continue
      ecr_n=$(sync_tool_field "$ecr_l" 1)
      ecr_st=$(sync_tool_state "$ecr_n" 2>/dev/null || echo unknown)
      ecr_ins_s=$(exec_stat_get "tool.$ecr_n")
      printf 'tool=%s\tstate=%s\tinstall_secs=%s\n' "$ecr_n" "$ecr_st" "${ecr_ins_s:--}"
    done < "$ecr_f"
  fi
}

fleet_handle_capabilities() { exec_capabilities_report "$2" > "$3/out"; fleet_ok "$3/out"; }

# A requirement is satisfied when the peer reports the tool `ok` OR the tool is
# simply on its PATH. `install`/`update` are not a refusal — they become
# `prepare` seconds in the estimate.
exec_cap_field() {  # <capfile> <key>
  fleet_meta_get_file "$1" "$2"
}
exec_cap_vendor() {  # <capfile> <vendor> <field: installed|auth|mean>
  awk -F'\t' -v v="vendor=$2" -v k="$3" '
    $1==v { for (i=2;i<=NF;i++) { split($i,a,"="); if (a[1]==k) { sub(/^[^=]*=/,"",$i); print $i; exit } } }' "$1"
}
exec_cap_tool() {  # <capfile> <tool> <field: state|install_secs>
  awk -F'\t' -v t="tool=$2" -v k="$3" '
    $1==t { for (i=2;i<=NF;i++) { split($i,a,"="); if (a[1]==k) { sub(/^[^=]*=/,"",$i); print $i; exit } } }' "$1"
}

# Local dispatch policy. An absent file allows all supported agents. An explicit
# list is an eligibility constraint, not an ordering that overrides completion
# time. Atomic replacement keeps concurrent planners from seeing half a list.
# The preference lives in the replicated fleet-level slot, not under tasks/,
# so setting it on one machine reaches the others through ordinary profile
# sync (address tools|-|-|agents.allowed) and can be excepted per machine.
# Absent means "no restriction": a fleet that has never expressed a preference
# must not be one where nothing is eligible.
exec_pref_file() { sync_agents_pref; }
exec_agent_allowed() {
  eaa_f=$(exec_pref_file)
  [ ! -f "$eaa_f" ] || grep -Fqx -- "$1" "$eaa_f"
}

exec_preferences() (
  case ${1:-show} in
    show)
      if [ -f "$(exec_pref_file)" ]; then cat "$(exec_pref_file)"
      else printf '%s\n' all; fi ;;
    reset) rm -f "$(exec_pref_file)" ;;
    set)
      shift
      [ "$#" -gt 0 ] || { echo "agents: specify at least one allowed agent" >&2; exit 1; }
      pref_dst=$(exec_pref_file)
      mkdir -p "$(dirname "$pref_dst")" || exit 1
      pref_tmp=$(mktemp "$pref_dst.XXXXXX") || exit 1
      trap 'rm -f "$pref_tmp"' EXIT
      for pref_vendor in "$@"; do
        pref_known=
        for pref_supported in $N2_VENDORS; do
          [ "$pref_vendor" != "$pref_supported" ] || pref_known=1
        done
        [ -n "$pref_known" ] || { echo "agents: unsupported agent: $pref_vendor" >&2; exit 1; }
        printf '%s\n' "$pref_vendor" >> "$pref_tmp"
      done
      sort -u "$pref_tmp" > "$pref_tmp.sorted" && mv "$pref_tmp.sorted" "$pref_tmp" || exit 1
      chmod 600 "$pref_tmp" && mv "$pref_tmp" "$pref_dst" ;;
    *) echo "agents: preferences show | set <agent>... | reset" >&2; exit 1 ;;
  esac
)

# --- eligibility and the estimate ------------------------------------------
# Eligibility is a hard filter and runs FIRST, per (machine, agent) pair.
# Only survivors are scored. `exec_plan` writes one line per candidate:
#
#   <peer> <machine> <vendor> <est> <assumed-count> <queue> <transfer> <prepare> <execute>
#
# and one `x` line per rejected pair naming the predicate that failed, so a
# pin against an ineligible pair can say WHY instead of silently moving on.

exec_cap_probe() {  # <capfile> <tool> -> ok|absent|install|update|unmanaged|""
  awk -F'\t' -v t="probe=$2" '$1==t { sub(/^state=/,"",$2); print $2; exit }' "$1"
}

exec_peer_caps() {  # <peerid> <outfile> [probe-file] -> 0 ok, 2 unreachable
  fleet_call "$1" capabilities "${3:-/dev/null}" > "$2" 2>/dev/null
}

exec_plan() {  # <workdir> <bytes> <pin-machine> <pin-vendor> <requires…newline file>
  ep_tmp=$1 ep_bytes=$2 ep_pm=$3 ep_pv=$4 ep_req=$5 ep_allow_unknown=${6:-}
  : > "$ep_tmp/plan"; : > "$ep_tmp/rejected"
  fleet_peer_ids | while read -r ep_p; do
    [ -n "$ep_p" ] || continue
    ep_mach=$(fleet_meta "$(fleet_peer_dir "$ep_p")" machine 2>/dev/null || echo "$ep_p")
    if [ -n "$ep_pm" ] && [ "$ep_pm" != "$ep_p" ] && [ "$ep_pm" != "$ep_mach" ]; then continue; fi
    if ! fleet_approved "$ep_p"; then
      printf 'x\t%s\t%s\t-\tnot-approved(%s)\n' "$ep_p" "$ep_mach" "$(fleet_peer_state "$ep_p")" >> "$ep_tmp/rejected"
      continue
    fi
    # A peer id is base64 and can contain "/", so it can never be a path element.
    ep_cf=$ep_tmp/cap.$(fleet_slug "$ep_p")
    if ! exec_peer_caps "$ep_p" "$ep_cf" "$ep_req"; then
      printf 'x\t%s\t%s\t-\tunreachable\n' "$ep_p" "$ep_mach" >> "$ep_tmp/rejected"
      continue
    fi
    # --- per-peer components, shared by every vendor on that peer ---
    ep_run=$(exec_cap_field "$ep_cf" running); case ${ep_run:-} in ''|*[!0-9]*) ep_run=0 ;; esac
    ep_mt=$(exec_cap_field "$ep_cf" mean_task)
    if [ -n "$ep_mt" ] && [ "$ep_mt" != - ]; then ep_qa=known; else ep_mt=$FLEET_EXEC_DEFAULT_TASK; ep_qa=assumed; fi
    ep_queue=$(( ep_run * ep_mt ))
    [ "$ep_run" = 0 ] && ep_qa=known   # an empty queue is a fact, not a guess
    ep_bps=$(exec_cap_field "$ep_cf" bps)
    if [ -n "$ep_bps" ] && [ "$ep_bps" != - ] && [ "$ep_bps" -gt 0 ] 2>/dev/null; then ep_ta=known
    else ep_bps=$FLEET_EXEC_DEFAULT_BPS; ep_ta=assumed; fi
    if [ "$ep_bytes" -gt 0 ] 2>/dev/null; then ep_xfer=$(( ep_bytes / ep_bps + 1 ))
    else ep_xfer=0; ep_ta=known; fi
    # prepare: the peer's missing/outdated REQUIRED tools only.
    ep_prep=0 ep_pa=known ep_missing=
    while IFS= read -r ep_t; do
      [ -n "$ep_t" ] || continue
      ep_st=$(exec_cap_probe "$ep_cf" "$ep_t")
      [ -n "$ep_st" ] || ep_st=$(exec_cap_tool "$ep_cf" "$ep_t" state)
      case $ep_st in
        ok) ;;
        install|update)
          ep_s=$(exec_cap_tool "$ep_cf" "$ep_t" install_secs)
          if [ -n "$ep_s" ] && [ "$ep_s" != - ]; then ep_prep=$(( ep_prep + ep_s ))
          else ep_prep=$(( ep_prep + 60 )); ep_pa=assumed; fi ;;
        # `absent` (not on PATH, not managed) and anything unrecognised are both
        # a refusal: we will not claim a machine can run work whose tools we
        # cannot account for.
        *) ep_missing="$ep_missing $ep_t" ;;
      esac
    done < "$ep_req"
    if [ -n "$ep_missing" ]; then
      printf 'x\t%s\t%s\t-\tmissing-requirement(%s)\n' "$ep_p" "$ep_mach" "$(printf '%s' "$ep_missing" | sed 's/^ //')" >> "$ep_tmp/rejected"
      continue
    fi
    for ep_v in $N2_VENDORS; do
      [ -z "$ep_pv" ] || [ "$ep_pv" = "$ep_v" ] || continue
      if [ "${N2_EXEC_TASK_MODE:-shell}" = prompt ] && ! exec_prompt_supported "$ep_v"; then
        printf 'x\t%s\t%s\t%s\tunsupported-prompt-adapter\n' "$ep_p" "$ep_mach" "$ep_v" >> "$ep_tmp/rejected"
        continue
      fi
      if ! exec_agent_allowed "$ep_v"; then
        printf 'x\t%s\t%s\t%s\tagent-excluded-by-preference\n' "$ep_p" "$ep_mach" "$ep_v" >> "$ep_tmp/rejected"
        continue
      fi
      ep_i=$(exec_cap_vendor "$ep_cf" "$ep_v" installed)
      [ "$ep_i" = yes ] || { [ -n "$ep_pv" ] &&
        printf 'x\t%s\t%s\t%s\tagent-not-installed\n' "$ep_p" "$ep_mach" "$ep_v" >> "$ep_tmp/rejected"; continue; }
      ep_au=$(exec_cap_vendor "$ep_cf" "$ep_v" auth)
      case $ep_au in
        yes) ;;
        unknown) [ -n "$ep_allow_unknown" ] ||
          { printf 'x\t%s\t%s\t%s\tagent-auth-unknown\n' "$ep_p" "$ep_mach" "$ep_v" >> "$ep_tmp/rejected"; continue; } ;;
        *) printf 'x\t%s\t%s\t%s\tagent-not-authenticated\n' "$ep_p" "$ep_mach" "$ep_v" >> "$ep_tmp/rejected"; continue ;;
      esac
      ep_ex=$(exec_cap_vendor "$ep_cf" "$ep_v" mean); ep_ea=known
      if [ -z "$ep_ex" ] || [ "$ep_ex" = - ]; then ep_ex=$FLEET_EXEC_DEFAULT_TASK; ep_ea=assumed; fi
      ep_as=0
      for ep_f in "$ep_qa" "$ep_ta" "$ep_pa" "$ep_ea"; do [ "$ep_f" = assumed ] && ep_as=$(( ep_as + 1 )); done
      printf '%s\t%s\t%s\t%s\t%s\t%s:%s\t%s:%s\t%s:%s\t%s:%s\n' \
        "$ep_p" "$ep_mach" "$ep_v" "$(( ep_queue + ep_xfer + ep_prep + ep_ex ))" "$ep_as" \
        "$ep_queue" "$ep_qa" "$ep_xfer" "$ep_ta" "$ep_prep" "$ep_pa" "$ep_ex" "$ep_ea" >> "$ep_tmp/plan"
    done
  done
  # Fastest expected completion first; ties break on fewest ASSUMED components
  # then peer id, so a peer cannot win a race purely by having no history.
  sort -t'	' -k4,4n -k5,5n -k1,1 "$ep_tmp/plan" > "$ep_tmp/plan.sorted" 2>/dev/null || true
  mv "$ep_tmp/plan.sorted" "$ep_tmp/plan" 2>/dev/null || true
  [ -s "$ep_tmp/plan" ]
}

# --- workspace handoff -----------------------------------------------------
# The workspace travels as a tar of the working tree exactly as it stands:
# staged, unstaged, untracked and deleted files all arrive in the state the
# source left them, because `.git` travels with the tree rather than being
# reconstructed from a commit. Nothing here reads or mutates the source beyond
# reading bytes — a dispatch never touches the operator's working copy.

exec_ws_pack() {  # <srcdir> <outfile>
  ewp_s=$1 ewp_o=$2
  [ -d "$ewp_s" ] || { echo "agents: not a directory: $ewp_s" >&2; return 1; }
  case $ewp_s in *..*) echo "agents: workspace path may not contain ..: $ewp_s" >&2; return 1 ;; esac
  ( cd "$ewp_s" 2>/dev/null && tar -cf - . ) > "$ewp_o" 2>/dev/null
}

# A received archive is inspected BEFORE extraction: an absolute member, a
# member that climbs out with .., or a link whose target does either, is a
# refusal for the whole archive — we do not extract "the safe part" of a
# hostile one.
exec_ws_verify() {  # <archive>
  tar -tf "$1" 2>/dev/null | while IFS= read -r ewv_m; do
    case $ewv_m in
      /*|../*|*/../*|*/..) echo bad; break ;;
    esac
  done | grep -q bad && return 1
  tar -tvf "$1" 2>/dev/null | awk '
    /^l/ { i=index($0," -> "); if (i) { t=substr($0,i+4);
           if (t ~ /^\// || t ~ /(^|\/)\.\.(\/|$)/) { print "bad"; exit } } }' | grep -q bad && return 1
  return 0
}

exec_ws_unpack() {  # <archive> <destdir>
  exec_ws_verify "$1" || { echo "agents: refusing unsafe archive" >&2; return 1; }
  mkdir -p "$2" || return 1
  ( cd "$2" && tar -xf - ) < "$1" 2>/dev/null
}

# --- the task bundle -------------------------------------------------------
# One tar carrying the request, the operator's context and (optionally) the
# workspace. Context travels WITH the task so the receiving agent does not
# repeat discovery the sender already paid for.

exec_bundle_build() {  # <dir> <command> <context-file|""> <workspace-dir|""> -> tar on stdout
  ebb_d=$1
  mkdir -p "$ebb_d/spec" || return 1
  printf '%s\n' "${6:-shell}" > "$ebb_d/spec/mode"
  printf '%s\n' "$2" > "$ebb_d/spec/command"
  if [ -n "${3:-}" ] && [ -f "$3" ]; then cp "$3" "$ebb_d/spec/context"; else : > "$ebb_d/spec/context"; fi
  if [ -n "${4:-}" ]; then exec_ws_pack "$4" "$ebb_d/spec/workspace.tar" || return 1; fi
  if [ -n "${5:-}" ] && [ -f "$5" ]; then cp "$5" "$ebb_d/spec/requires" || return 1; fi
  ( cd "$ebb_d" && tar -cf - spec ) 2>/dev/null
}

# --- worker side: accepting and running a task -----------------------------
# payload: task=<id>\nvendor=<v>\norigin=<peerid>\nlabel=<text>\n--\n<base64 bundle>

exec_work_dir() { echo "$fleet_root/tasks/work/$1"; }

fleet_handle_task_start() {  # <from> <payload> <dir>
  exec_init
  hts_from=$1
  fleet_approved "$hts_from" || { echo "ERR not-approved"; return 1; }
  hts_id=$(fleet_header "$2" task); hts_v=$(fleet_header "$2" vendor)
  hts_lab=$(fleet_header "$2" label)
  exec_valid_id "$hts_id" || { echo "ERR bad-task-id"; return 1; }
  case ${hts_v:-} in ''|*[!a-z0-9-]*) echo "ERR bad-vendor"; return 1 ;; esac
  hts_d=$(exec_task_dir "$hts_id")
  # Re-delivery of a task we already hold is an acknowledgement, never a second
  # run: a retried delivery must not start the work twice.
  if [ -d "$hts_d" ]; then
    printf 'accepted %s %s\n' "$hts_id" "$(exec_meta "$hts_id" state)" > "$3/out"
    fleet_ok "$3/out"; return 0
  fi
  hts_w=$(exec_work_dir "$hts_id")
  mkdir -p "$hts_d" "$hts_w" || { echo "ERR task-store"; return 1; }
  awk 'f{print} /^--$/{f=1}' "$2" | base64 -d > "$3/bundle" 2>/dev/null
  [ -s "$3/bundle" ] || { rm -rf "$hts_d" "$hts_w"; echo "ERR empty-bundle"; return 1; }
  if ! exec_ws_unpack "$3/bundle" "$hts_w"; then
    rm -rf "$hts_d" "$hts_w"; echo "ERR unsafe-bundle"; return 1
  fi
  if [ -f "$hts_w/spec/workspace.tar" ]; then
    if ! exec_ws_unpack "$hts_w/spec/workspace.tar" "$hts_w/workspace"; then
      rm -rf "$hts_d" "$hts_w"; echo "ERR unsafe-workspace"; return 1
    fi
    rm -f "$hts_w/spec/workspace.tar"
  fi
  exec_meta_set "$hts_id" role worker
  exec_meta_set "$hts_id" origin "$hts_from"
  exec_meta_set "$hts_id" vendor "$hts_v"
  exec_meta_set "$hts_id" label "$hts_lab"
  exec_meta_set "$hts_id" created "$(fleet_now)"
  exec_set_state "$hts_id" accepted
  exec_run_local "$hts_id" &
  printf 'accepted %s\n' "$hts_id" > "$3/out"
  fleet_ok "$3/out"
}

# Recheck on the receiving machine: capabilities can change after planning.
# Share the managed-installer lock; a requirement never authorizes new software.
exec_prepare_requirements() (  # <requirements-file>
  [ -f "$1" ] || exit 0
  sync_res_lock "tools-apply" || exit 1
  trap 'sync_res_unlock "tools-apply"' EXIT
  while IFS= read -r epr_tool || [ -n "$epr_tool" ]; do
    [ -n "$epr_tool" ] || continue
    case $epr_tool in *[!A-Za-z0-9._+-]*) exit 1 ;; esac
    epr_state=$(sync_tool_state "$epr_tool") || exit 1
    case $epr_state in
      ok) ;;
      unmanaged) command -v "$epr_tool" >/dev/null 2>&1 || exit 1 ;;
      install|update)
        ( cmd_fleet_tools install "$epr_tool" ) >/dev/null 2>&1 || exit 1
        # Install returns success for a safe deferral too. Do not launch work
        # until the required version really exists.
        [ "$(sync_tool_state "$epr_tool")" = ok ] || exit 1 ;;
      *) exit 1 ;;
    esac
  done < "$1"
)

# Prompt adapters use the same per-provider profile isolation as `agents run`.
# No permission-bypass flags are added. Unsupported providers fail closed.
exec_prompt_supported() { case $1 in claude|codex) return 0 ;; *) return 1 ;; esac; }
exec_invoke_prompt() (
  eip_vendor=$1 eip_spec=$2
  exec_prompt_supported "$eip_vendor" || { echo "unsupported prompt adapter" >&2; exit 125; }
  eip_profile=$(active_profile "$eip_vendor") || exit 125
  eip_cfg=$(config_dir "$eip_profile" "$eip_vendor") || exit 125
  [ -d "$eip_cfg" ] || { echo "active profile slot is missing" >&2; exit 125; }
  eip_cli=$(vendor_cli "$eip_vendor")
  command -v "$eip_cli" >/dev/null 2>&1 || exit 127
  eip_env=$(vendor_env "$eip_vendor")
  [ -n "$eip_env" ] || exit 125
  eip_value=$(vendor_env_value "$eip_vendor" "$eip_cfg") || exit 125
  # The prompt stays on stdin, outside process arguments and fleet journals.
  {
    printf 'Task:\n'; cat "$eip_spec/command"
    printf '\nContinuation context (constraints, decisions, progress):\n'
    cat "$eip_spec/context"
  } | case $eip_vendor in
    claude) env "$eip_env=$eip_value" "$eip_cli" --print ;;
    codex) env "$eip_env=$eip_value" "$eip_cli" exec - ;;
  esac
)

# The run itself. Detached from the request that delivered it, because a task
# outlives its dispatch: the link dropping mid-run must not end the work.
exec_run_local() {  # <id>
  erl_id=$1 erl_d=$(exec_task_dir "$1") erl_w=$(exec_work_dir "$1")
  erl_cmd=$(cat "$erl_w/spec/command" 2>/dev/null)
  erl_mode=$(cat "$erl_w/spec/mode" 2>/dev/null)
  erl_mode=${erl_mode:-shell}
  [ -n "$erl_cmd" ] || { exec_set_state "$erl_id" failed "no command"; return 0; }
  erl_cwd=$erl_w/workspace; [ -d "$erl_cwd" ] || erl_cwd=$erl_w
  mkdir -p "$erl_d/out" 2>/dev/null
  erl_start=$(fleet_now)
  exec_meta_set "$erl_id" started "$erl_start"
  exec_set_state "$erl_id" preparing
  if ! exec_prepare_requirements "$erl_w/spec/requires"; then
    exec_meta_set "$erl_id" rc 125
    exec_meta_set "$erl_id" ended "$(fleet_now)"
    exec_set_state "$erl_id" failed "required tools unavailable or deferred"
    exec_announce "$erl_id"
    return 0
  fi
  exec_set_state "$erl_id" running
  # The liveness record `sync` reads to decide whether a disruptive managed
  # update may apply now. Written before the command starts and removed only
  # after it ends, so a deferral decision never races the work.
  #
  # The pid must be the process actually doing the work. `$$` is the shell that
  # was invoked, and it is NOT re-set in a subshell — exec_run_local already
  # runs backgrounded, so `$$` named the short-lived request handler, which had
  # exited by the time sync looked. sync_tasks_reap then read a dead owner,
  # filed the record stale, and a --disruptive update applied straight through
  # live work. Backgrounding the command and taking `$!` names the real one.
  #
  # The record is opened before the command is launched and only then given its
  # owner. In between it carries no pid line, which sync_tasks_reap treats as
  # "no owner declared -> stays active" — so the window between launch and
  # knowing the pid errs toward deferring an update, never toward running one.
  mkdir -p "$(exec_active_dir)" 2>/dev/null
  printf 'task %s\n' "$erl_id" > "$(exec_active_dir)/$erl_id" 2>/dev/null || true
  (
    cd "$erl_cwd" 2>/dev/null || exit 127
    export N2_FLEET_TASK=$erl_id N2_FLEET_CONTEXT=$erl_w/spec/context
    case $erl_mode in
      shell) sh -c "$erl_cmd" ;;
      prompt) exec_invoke_prompt "$(exec_meta "$erl_id" vendor)" "$erl_w/spec" ;;
      *) echo "unsupported task mode" >&2; exit 125 ;;
    esac
  ) > "$erl_d/out/stdout" 2> "$erl_d/out/stderr" &
  erl_pid=$!
  printf 'task %s\npid %s\n' "$erl_id" "$erl_pid" > "$(exec_active_dir)/$erl_id" 2>/dev/null || true
  wait "$erl_pid"
  erl_rc=$?
  rm -f "$(exec_active_dir)/$erl_id" 2>/dev/null || true
  exec_meta_set "$erl_id" rc "$erl_rc"
  exec_meta_set "$erl_id" ended "$(fleet_now)"
  erl_secs=$(( $(fleet_now) - erl_start ))
  exec_stat_add mean_task "$erl_secs"
  exec_stat_add "vendor.$(exec_meta "$erl_id" vendor)" "$erl_secs"
  if [ "$erl_rc" = 0 ]; then exec_set_state "$erl_id" completed "rc=0"
  else exec_set_state "$erl_id" failed "rc=$erl_rc"; fi
  # Tell the fleet. Best effort by design: if the origin is offline the task
  # is already finished and recorded here, and reconnect reconciliation — not
  # a retry — is what closes the gap.
  exec_announce "$erl_id"
}

# --- status, reporting and reconciliation ----------------------------------

exec_status_line() {  # <id>
  esl_d=$(exec_task_dir "$1")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$(exec_meta "$1" state)" \
    "$(exec_meta "$1" vendor)" "$(exec_meta "$1" rc)" \
    "$(exec_meta "$1" label)" "$(exec_meta "$1" machine)"
}

fleet_handle_task_status() {
  hst_id=$(fleet_header "$2" task)
  exec_valid_id "$hst_id" || { echo "ERR bad-task-id"; return 1; }
  [ -d "$(exec_task_dir "$hst_id")" ] || { echo "ERR unknown-task"; return 1; }
  {
    printf 'task=%s\n' "$hst_id"
    printf 'state=%s\n' "$(exec_meta "$hst_id" state)"
    printf 'rc=%s\n' "$(exec_meta "$hst_id" rc)"
    printf 'started=%s\n' "$(exec_meta "$hst_id" started)"
    printf 'ended=%s\n' "$(exec_meta "$hst_id" ended)"
  } > "$3/out"
  fleet_ok "$3/out"
}

# --- notifications ---------------------------------------------------------
# Two surfaces, one record. `notices` is the in-app feed the tray and the CLI
# both read; the native banner is fired alongside it. Delivery is best effort
# on the banner only — the feed is the durable half, so a missed banner never
# loses the event.

exec_notices() { echo "$fleet_root/tasks/notices"; }

exec_notify() {  # <kind> <task> <machine> <text>
  en_k=$1 en_t=$2 en_m=$3; shift 3
  mkdir -p "$fleet_root/tasks" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$(fleet_now)" "$en_k" "$en_t" "$en_m" "$*" \
    >> "$(exec_notices)" 2>/dev/null || true
  # The native banner. N2_FLEET_NOTIFY exists so a test can observe delivery
  # without a desktop session; unset, we use the system notifier.
  if [ -n "${N2_FLEET_NOTIFY:-}" ]; then
    N2_NOTIFY_KIND=$en_k N2_NOTIFY_TASK=$en_t N2_NOTIFY_MACHINE=$en_m \
      sh -c "$N2_FLEET_NOTIFY" "$en_k" "$*" >/dev/null 2>&1 || true
  elif [ -z "${N2_FLEET_NO_BANNER:-}" ] && command -v osascript >/dev/null 2>&1; then
    en_msg=$(printf '%s' "$*" | tr -d '"')
    osascript -e "display notification \"$en_msg\" with title \"n2 Agents\" subtitle \"$en_m\"" \
      >/dev/null 2>&1 || true
  fi
}

# Inbound peer event. Only an approved peer may write to our feed, and the
# task id it names is recorded as-is — we never start, retry or mutate work on
# the strength of somebody else's event.
fleet_handle_task_event() {  # <from> <payload> <dir>
  fleet_approved "$1" || { echo "ERR not-approved"; return 1; }
  hte_id=$(fleet_header "$2" task); hte_k=$(fleet_header "$2" kind)
  hte_m=$(fleet_header "$2" machine); hte_d=$(fleet_header "$2" detail)
  exec_valid_id "$hte_id" || { echo "ERR bad-task-id"; return 1; }
  case ${hte_k:-} in completed|failed|disconnected|reconnected|started) ;;
    *) echo "ERR bad-kind"; return 1 ;; esac
  # If we are the dispatcher of this task, record the outcome on our copy too.
  if [ -d "$(exec_task_dir "$hte_id")" ] && [ "$(exec_meta "$hte_id" role)" = dispatcher ]; then
    case $hte_k in completed|failed) exec_set_state "$hte_id" "$hte_k" "$hte_d" ;; esac
  fi
  exec_notify "$hte_k" "$hte_id" "${hte_m:-$1}" "$hte_d"
  printf 'noted\n' > "$3/out"; fleet_ok "$3/out"
}

# Fan-out. Every online peer sees completion and disconnection, not just the
# dispatcher, because the operator may be sitting at any machine in the fleet.
exec_fanout() {  # <kind> <id> <detail>
  ef_k=$1 ef_id=$2 ef_det=$3
  ef_t=$(mktemp "${TMPDIR:-/tmp}/n2ev.XXXXXX") || return 0
  { printf 'task=%s\n' "$ef_id"; printf 'kind=%s\n' "$ef_k"
    printf 'machine=%s\n' "$(fleet_self_machine)"
    printf 'detail=%s\n' "$ef_det"; } > "$ef_t"
  exec_notify "$ef_k" "$ef_id" "$(fleet_self_machine)" "$ef_det"
  for ef_p in $(fleet_peer_ids); do
    [ "$ef_p" = "$(fleet_self_id)" ] && continue
    fleet_approved "$ef_p" || continue
    fleet_call "$ef_p" task-event "$ef_t" >/dev/null 2>&1 || true
  done
  rm -f "$ef_t"
}

exec_announce() {  # <id> — worker side, after the run ends
  ea_s=$(exec_meta "$1" state)
  exec_fanout "$ea_s" "$1" "rc=$(exec_meta "$1" rc) $(exec_meta "$1" label)"
}

# --- dispatcher side -------------------------------------------------------

exec_dispatch() {  # <command> <context-file|""> <workspace|""> <pin-machine> <pin-vendor> <requires-file> <label> <allow-unknown>
  ed_cmd=$1 ed_ctx=$2 ed_ws=$3 ed_pm=$4 ed_pv=$5 ed_req=$6 ed_lab=$7 ed_au=$8 ed_mode=${9:-shell}
  ed_t=$(mktemp -d "${TMPDIR:-/tmp}/n2disp.XXXXXX") || return 1
  ed_id=$(exec_new_id)
  if ! exec_bundle_build "$ed_t/b" "$ed_cmd" "$ed_ctx" "$ed_ws" "$ed_req" "$ed_mode" > "$ed_t/bundle"; then
    rm -rf "$ed_t"; echo "agents: could not build the task bundle" >&2; return 1
  fi
  ed_bytes=$(wc -c < "$ed_t/bundle" | tr -d ' ')
  if ! N2_EXEC_TASK_MODE=$ed_mode exec_plan "$ed_t" "$ed_bytes" "$ed_pm" "$ed_pv" "$ed_req" "$ed_au"; then
    echo "agents: no eligible machine for this task" >&2
    [ -s "$ed_t/rejected" ] && cat "$ed_t/rejected" >&2
    rm -rf "$ed_t"; return 1
  fi
  # Persist the destination before delivery. A transport failure cannot tell
  # us whether the worker accepted the request; only reconciliation can.
  ed_rc=1
  while IFS='	' read -r ed_p ed_mach ed_v ed_eta ed_as ed_rest; do
    [ -n "$ed_p" ] || continue
    ed_d=$(exec_task_dir "$ed_id"); mkdir -p "$ed_d" || break
    exec_meta_set "$ed_id" role dispatcher
    exec_meta_set "$ed_id" peer "$ed_p"
    exec_meta_set "$ed_id" machine "$ed_mach"
    exec_meta_set "$ed_id" vendor "$ed_v"
    exec_meta_set "$ed_id" label "$ed_lab"
    exec_meta_set "$ed_id" eta "$ed_eta"
    exec_meta_set "$ed_id" assumed "$ed_as"
    exec_meta_set "$ed_id" created "$(fleet_now)"
    exec_set_state "$ed_id" dispatching "peer=$ed_p vendor=$ed_v"
    { printf 'task=%s\n' "$ed_id"; printf 'vendor=%s\n' "$ed_v"
      printf 'label=%s\n' "$ed_lab"; printf -- '--\n'
      base64 < "$ed_t/bundle"; } > "$ed_t/req"
    if fleet_call "$ed_p" task-start "$ed_t/req" > "$ed_t/rep" 2>/dev/null &&
       awk -v id="$ed_id" '$1=="accepted" && $2==id {ok=1} END {exit !ok}' "$ed_t/rep"; then
      # Completion events can arrive before the acknowledgment. Do not move
      # a running or completed task backwards to dispatched.
      if [ "$(exec_meta "$ed_id" state)" = dispatching ]; then
        exec_set_state "$ed_id" dispatched "peer=$ed_p vendor=$ed_v eta=${ed_eta}s assumed=$ed_as"
      fi
    else
      exec_set_state "$ed_id" unreachable "delivery uncertain peer=$ed_p; reconcile before retry"
      exec_fanout disconnected "$ed_id" "Delivery to $ed_mach is uncertain; waiting for reconciliation"
      echo "agents: delivery uncertain for $ed_id on $ed_mach; no other worker was started" >&2
    fi
    printf '%s\t%s\t%s\t%ss\tassumed=%s\n' "$ed_id" "$ed_mach" "$ed_v" "$ed_eta" "$ed_as"
    ed_rc=0; break
  done < "$ed_t/plan"
  rm -rf "$ed_t"; return $ed_rc
}

# --- explicit output movement ----------------------------------------------
# Nothing below runs on its own. A finished task's outputs stay where the task
# ran until the operator asks for them, and they are never broadcast.

fleet_handle_task_fetch() {  # <from> <payload> <dir>
  fleet_approved "$1" || { echo "ERR not-approved"; return 1; }
  htf_id=$(fleet_header "$2" task)
  exec_valid_id "$htf_id" || { echo "ERR bad-task-id"; return 1; }
  htf_d=$(exec_task_dir "$htf_id")
  [ -d "$htf_d" ] || { echo "ERR unknown-task"; return 1; }
  [ "$(exec_meta "$htf_id" origin)" = "$1" ] || { echo "ERR not-your-task"; return 1; }
  mkdir -p "$htf_d/out" 2>/dev/null
  ( cd "$htf_d" && tar -cf - out ) > "$3/out" 2>/dev/null
  fleet_ok "$3/out"
}

exec_fetch() {  # <id> <destdir>
  ef_id=$1 ef_dest=$2
  ef_p=$(exec_meta "$ef_id" peer)
  [ -n "$ef_p" ] || { echo "agents: $ef_id was not dispatched from here" >&2; return 1; }
  ef_t=$(mktemp -d "${TMPDIR:-/tmp}/n2fetch.XXXXXX") || return 1
  printf 'task=%s\n' "$ef_id" > "$ef_t/req"
  if ! fleet_call "$ef_p" task-fetch "$ef_t/req" > "$ef_t/tar" 2>/dev/null; then
    rm -rf "$ef_t"; echo "agents: $(exec_meta "$ef_id" machine) did not answer" >&2; return 2
  fi
  if ! exec_ws_verify "$ef_t/tar"; then
    rm -rf "$ef_t"; echo "agents: refused an unsafe result archive" >&2; return 1
  fi
  mkdir -p "$ef_dest" || { rm -rf "$ef_t"; return 1; }
  exec_ws_unpack "$ef_t/tar" "$ef_dest" || { rm -rf "$ef_t"; return 1; }
  rm -rf "$ef_t"
  printf '%s\n' "$ef_dest/out"
}

# Distribution: an explicit operator act, one named machine or the whole fleet.
fleet_handle_task_deliver() {  # <from> <payload> <dir>
  fleet_approved "$1" || { echo "ERR not-approved"; return 1; }
  htd_n=$(fleet_header "$2" name)
  case ${htd_n:-} in ''|*/*|.*) echo "ERR bad-name"; return 1 ;; esac
  awk 'f{print} /^--$/{f=1}' "$2" | base64 -d > "$3/payload.tar" 2>/dev/null
  [ -s "$3/payload.tar" ] || { echo "ERR empty"; return 1; }
  exec_ws_verify "$3/payload.tar" || { echo "ERR unsafe-archive"; return 1; }
  htd_dest=$fleet_root/tasks/inbox/$htd_n
  # A delivery replaces only its own named slot. Unrelated content at the
  # destination is not touched.
  rm -rf "$htd_dest"; mkdir -p "$htd_dest" || { echo "ERR inbox"; return 1; }
  exec_ws_unpack "$3/payload.tar" "$htd_dest" || { rm -rf "$htd_dest"; echo "ERR unpack"; return 1; }
  exec_notify delivered - "$1" "received $htd_n"
  printf '%s\n' "$htd_dest" > "$3/out"; fleet_ok "$3/out"
}

exec_distribute() {  # <srcdir> <name> <target: peerid|machine|--all>
  ed2_src=$1 ed2_name=$2 ed2_to=$3
  [ -d "$ed2_src" ] || { echo "agents: not a directory: $ed2_src" >&2; return 1; }
  ed2_t=$(mktemp -d "${TMPDIR:-/tmp}/n2dist.XXXXXX") || return 1
  exec_ws_pack "$ed2_src" "$ed2_t/tar" || { rm -rf "$ed2_t"; return 1; }
  { printf 'name=%s\n' "$ed2_name"; printf -- '--\n'; base64 < "$ed2_t/tar"; } > "$ed2_t/req"
  ed2_any=1
  for ed2_p in $(fleet_peer_ids); do
    [ "$ed2_p" = "$(fleet_self_id)" ] && continue
    fleet_approved "$ed2_p" || continue
    ed2_m=$(fleet_meta "$(fleet_peer_dir "$ed2_p")" machine 2>/dev/null)
    if [ "$ed2_to" != --all ] && [ "$ed2_to" != "$ed2_p" ] && [ "$ed2_to" != "$ed2_m" ]; then continue; fi
    if fleet_call "$ed2_p" task-deliver "$ed2_t/req" > "$ed2_t/rep" 2>/dev/null; then
      printf 'sent\t%s\t%s\n' "$ed2_m" "$(cat "$ed2_t/rep")"; ed2_any=0
    else
      printf 'failed\t%s\tunreachable\n' "$ed2_m"
    fi
  done
  rm -rf "$ed2_t"
  [ "$ed2_any" = 0 ] || { echo "agents: no approved machine matched '$ed2_to'" >&2; return 1; }
}

# --- reconciliation --------------------------------------------------------
# An unreachable worker is a statement about the link. We say so, we notify,
# and we stop. No second run starts here, ever; the operator decides.

exec_reconcile() {  # [id…] — default: every non-terminal dispatched task
  er_t=$(mktemp -d "${TMPDIR:-/tmp}/n2rec.XXXXXX") || return 1
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$er_t/ids"
  else
    : > "$er_t/ids"
    for er_d in "$(exec_db)"/*; do [ -d "$er_d" ] || continue
      er_i=$(basename "$er_d")
      [ "$(exec_meta "$er_i" role)" = dispatcher ] || continue
      case $(exec_meta "$er_i" state) in completed|failed) ;; *) echo "$er_i" >> "$er_t/ids" ;; esac
    done
  fi
  while read -r er_id; do
    [ -n "$er_id" ] || continue
    er_p=$(exec_meta "$er_id" peer); [ -n "$er_p" ] || continue
    er_was=$(exec_meta "$er_id" state)
    printf 'task=%s\n' "$er_id" > "$er_t/req"
    if ! fleet_call "$er_p" task-status "$er_t/req" > "$er_t/rep" 2>/dev/null; then
      if [ "$er_was" != unreachable ]; then
        exec_set_state "$er_id" unreachable "peer=$er_p"
        exec_fanout disconnected "$er_id" "$(exec_meta "$er_id" machine) went away while running $(exec_meta "$er_id" label)"
      fi
      printf '%s\tunreachable\t%s\n' "$er_id" "$(exec_meta "$er_id" machine)"
      continue
    fi
    er_st=$(fleet_header "$er_t/rep" state); er_rc=$(fleet_header "$er_t/rep" rc)
    [ -n "$er_st" ] || er_st=unknown
    if [ "$er_st" != "$er_was" ]; then
      exec_meta_set "$er_id" rc "$er_rc"
      exec_set_state "$er_id" "$er_st" "reconciled rc=$er_rc"
      case $er_st in completed|failed)
        # The work finished while we could not see it. Reconciling reports the
        # real outcome; it does not re-run anything.
        exec_notify "$er_st" "$er_id" "$(exec_meta "$er_id" machine)" "reconciled after reconnect rc=$er_rc" ;;
      esac
    elif [ "$er_was" = unreachable ]; then
      exec_set_state "$er_id" "$er_st" "reconnected"
    fi
    printf '%s\t%s\t%s\n' "$er_id" "$er_st" "$(exec_meta "$er_id" machine)"
  done < "$er_t/ids"
  rm -rf "$er_t"
}

# Retry is an operator verb and nothing else calls it. It mints a NEW task id
# and records `retry_of`, so the original and its retry are never conflated:
# an offline worker that finishes its copy still reconciles under its own id.
exec_retry() {  # <id> <pin-machine> <pin-vendor> <allow-unknown>
  ert_id=$1
  [ -d "$(exec_task_dir "$ert_id")" ] || { echo "agents: unknown task: $ert_id" >&2; return 1; }
  ert_w=$fleet_root/tasks/sent/$ert_id
  [ -d "$ert_w/spec" ] || { echo "agents: the original request for $ert_id was not kept here" >&2; return 1; }
  ert_ws=; [ -d "$ert_w/workspace" ] && ert_ws=$ert_w/workspace
  ert_new=$(exec_dispatch "$(cat "$ert_w/spec/command")" "$ert_w/spec/context" "$ert_ws" \
    "$2" "$3" "$ert_w/spec/requires" "$(exec_meta "$ert_id" label)" "$4" "$(cat "$ert_w/spec/mode" 2>/dev/null || echo shell)") || return 1
  # `read` on a line with no trailing newline sets the variable and still
  # returns non-zero, so a `while read` loop here silently never ran and the
  # retry lost its back-link. Take the field directly.
  ert_nid=$(printf '%s' "$ert_new" | cut -f1)
  [ -n "$ert_nid" ] && exec_meta_set "$ert_nid" retry_of "$ert_id"
  exec_meta_set "$ert_id" retried_as "$ert_nid"
  printf '%s' "$ert_new"
}

# --- CLI -------------------------------------------------------------------

exec_usage() {
  cat <<'USAGE'
agents fleet task run <command>        dispatch to the fastest eligible machine
    --prompt                          treat the request as a prompt for the selected agent
    --workspace <dir>                  send the working tree, dirty files and all
    --context <file>                   carry findings/decisions so the agent need not rediscover
    --requires <tool>[,<tool>…]        hard requirement; an unaccountable tool excludes the machine
    --machine <id|name>                pin the machine
    --agent <vendor>                   pin the agent
    --label <text>                     a name for the notifications
    --allow-unknown-auth               allow a machine whose agent auth cannot be proven
    --plan                             show the ranked candidates and refusals, dispatch nothing
agents fleet task preferences show | set <agent>... | reset
                                      allowed agents on this dispatcher; pins respect this list
agents fleet task list                 tasks this machine dispatched or ran
agents fleet task show <id>            one task in full
agents fleet task reconcile [id…]      re-read worker state; report, never retry
agents fleet task retry <id>           explicit retry as a NEW task
agents fleet task fetch <id> <dir>     pull outputs here — explicit, never automatic
agents fleet task distribute <dir> --name <n> (--machine <m> | --all)
agents fleet task notices              the fleet notification feed
USAGE
}

cmd_fleet_task() {
  exec_need
  tverb=${1:-list}; [ $# -ge 1 ] && shift
  case $tverb in
    preferences) exec_preferences "$@" ;;
    run)
      tmode=shell tcmd= tws= tctx= tpm= tpv= tlab= tplan= tau= treq=$(mktemp "${TMPDIR:-/tmp}/n2req.XXXXXX")
      : > "$treq"
      while [ $# -gt 0 ]; do case $1 in
        --prompt) tmode=prompt; shift ;;
        --workspace) tws=$2; shift 2 ;;
        --context) tctx=$2; shift 2 ;;
        --requires) printf '%s\n' "$2" | tr ',' '\n' >> "$treq"; shift 2 ;;
        --machine) tpm=$2; shift 2 ;;
        --agent) tpv=$2; shift 2 ;;
        --label) tlab=$2; shift 2 ;;
        --allow-unknown-auth) tau=1; shift ;;
        --plan) tplan=1; shift ;;
        --) shift; tcmd=$*; break ;;
        -*) fleet_die "unknown option: $1" ;;
        *) tcmd=$* ; break ;;
      esac; done
      [ -n "$tcmd" ] || { rm -f "$treq"; fleet_die "usage: agents fleet task run [options] <command>"; }
      [ -z "$tws" ] || [ -d "$tws" ] || { rm -f "$treq"; fleet_die "not a directory: $tws"; }
      if [ -n "$tplan" ]; then
        tpt=$(mktemp -d "${TMPDIR:-/tmp}/n2plan.XXXXXX")
        tbytes=0
        if [ -n "$tws" ]; then exec_ws_pack "$tws" "$tpt/ws" && tbytes=$(wc -c < "$tpt/ws" | tr -d ' '); fi
        if N2_EXEC_TASK_MODE=$tmode exec_plan "$tpt" "$tbytes" "$tpm" "$tpv" "$treq" "$tau"; then
          printf 'rank\tpeer\tmachine\tagent\teta\tassumed\tqueue\ttransfer\tprepare\texecute\n'
          trk=0
          while IFS='	' read -r a b c d e f g h i; do
            trk=$(( trk + 1 ))
            printf '%s\t%s\t%s\t%s\t%ss\t%s\t%s\t%s\t%s\t%s\n' "$trk" "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i"
          done < "$tpt/plan"
        fi
        [ -s "$tpt/rejected" ] && { echo; echo "excluded:"; cat "$tpt/rejected"; }
        rm -rf "$tpt" "$treq"; return 0
      fi
      tout=$(exec_dispatch "$tcmd" "$tctx" "$tws" "$tpm" "$tpv" "$treq" "${tlab:-Fleet task}" "$tau" "$tmode") || { rm -f "$treq"; return 1; }
      # Keep the request so an explicit retry does not have to reconstruct it.
      tid=$(printf '%s' "$tout" | cut -f1)
      tsent=$fleet_root/tasks/sent/$tid
      mkdir -p "$tsent/spec"
      printf '%s\n' "$tcmd" > "$tsent/spec/command"
      printf '%s\n' "$tmode" > "$tsent/spec/mode"
      cp "$treq" "$tsent/spec/requires"
      if [ -n "$tctx" ] && [ -f "$tctx" ]; then cp "$tctx" "$tsent/spec/context"; else : > "$tsent/spec/context"; fi
      [ -n "$tws" ] && { mkdir -p "$tsent/workspace"; ( cd "$tws" && tar -cf - . ) | ( cd "$tsent/workspace" && tar -xf - ) 2>/dev/null; }
      rm -f "$treq"
      printf '%s' "$tout"
      ;;
    list)
      for td in "$(exec_db)"/*; do [ -d "$td" ] || continue; exec_status_line "$(basename "$td")"; done
      ;;
    show)
      [ -n "${1:-}" ] || fleet_die "usage: agents fleet task show <id>"
      [ -d "$(exec_task_dir "$1")" ] || fleet_die "unknown task: $1"
      for tk in role state peer machine vendor label rc eta assumed created started ended retry_of retried_as origin; do
        tv=$(exec_meta "$1" "$tk"); [ -n "$tv" ] && printf '%s\t%s\n' "$tk" "$tv"
      done
      [ -f "$(exec_task_dir "$1")/events" ] && { echo; cat "$(exec_task_dir "$1")/events"; }
      ;;
    reconcile) exec_reconcile "$@" ;;
    retry)
      [ -n "${1:-}" ] || fleet_die "usage: agents fleet task retry <id> [--machine m] [--agent v]"
      trid=$1; shift; trm= trv= trau=
      while [ $# -gt 0 ]; do case $1 in
        --machine) trm=$2; shift 2 ;; --agent) trv=$2; shift 2 ;;
        --allow-unknown-auth) trau=1; shift ;; *) fleet_die "unknown option: $1" ;; esac; done
      exec_retry "$trid" "$trm" "$trv" "$trau"
      ;;
    fetch)
      [ -n "${2:-}" ] || fleet_die "usage: agents fleet task fetch <id> <dir>"
      exec_fetch "$1" "$2"
      ;;
    distribute)
      [ -n "${1:-}" ] || fleet_die "usage: agents fleet task distribute <dir> --name <n> (--machine <m> | --all)"
      tdsrc=$1; shift; tdname= tdto=
      while [ $# -gt 0 ]; do case $1 in
        --name) tdname=$2; shift 2 ;; --machine) tdto=$2; shift 2 ;;
        --all) tdto=--all; shift ;; *) fleet_die "unknown option: $1" ;; esac; done
      [ -n "$tdname" ] || fleet_die "distribution needs --name"
      [ -n "$tdto" ] || fleet_die "distribution needs --machine <m> or --all"
      exec_distribute "$tdsrc" "$tdname" "$tdto"
      ;;
    notices) [ -f "$(exec_notices)" ] && cat "$(exec_notices)"; return 0 ;;
    help|-h|--help) exec_usage ;;
    *) exec_usage >&2; fleet_die "unknown task verb: $tverb" ;;
  esac
}
