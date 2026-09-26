# fleet-sync.sh — shared profile replication, conflict handling, managed tools.
# Sourced by `agents` after fleet.sh; see the "Profile replication and managed
# utilities" section of docs/fleet-design.md for the contract this implements.
# POSIX sh.
#
# The rules that matter, restated where they are enforced rather than only in
# the doc, because both are easy to erode by accident:
#   * a resource is addressed relatively, never by absolute path;
#   * the merge table below cannot express last-writer-wins or primary-wins;
#   * a conflict is preserved and pinned, never resolved by code;
#   * secret values never reach the journal, a header, or stdout.

sync_root() { echo "$fleet_root/sync"; }
sync_state_file() { echo "$(sync_root)/state"; }
sync_exceptions_file() { echo "$(sync_root)/exceptions"; }
sync_conflict_dir() { echo "$(sync_root)/conflicts"; }
sync_auth_optin_file() { echo "$(sync_root)/auth-optin"; }
sync_tools_manifest() { echo "$fleet_root/tools/manifest"; }

# The managed-tool manifest replicates like any other resource, under a
# reserved address whose profile and vendor are '-' because it is a fleet
# fact, not a per-profile one. Keeping it in the same table means a tool the
# operator designates on one machine becomes designated everywhere by the
# ordinary merge, with the ordinary conflict and exception rules.
SYNC_TOOLS_ADDR='tools|-|-|manifest'
sync_addr_is_tools() { [ "$1" = "$SYNC_TOOLS_ADDR" ]; }
# The allowed-agent preference shares the reserved fleet-level slot. It is a
# separate address from the manifest so an exception can withhold one without
# withholding the other.
SYNC_AGENTS_REL='agents.allowed'
SYNC_AGENTS_ADDR='tools|-|-|agents.allowed'
sync_agents_pref() { echo "$fleet_root/tools/$SYNC_AGENTS_REL"; }

sync_init() {
  mkdir -p "$(sync_root)" "$(sync_conflict_dir)" "$fleet_root/tools" 2>/dev/null
  : > "$(sync_state_file)" 2>/dev/null || true
  [ -f "$(sync_exceptions_file)" ] || : > "$(sync_exceptions_file)"
  [ -f "$(sync_auth_optin_file)" ] || : > "$(sync_auth_optin_file)"
  [ -f "$(sync_tools_manifest)" ] || : > "$(sync_tools_manifest)"
}

sync_ready() { [ -d "$(sync_root)" ]; }
sync_need() {
  fleet_have_identity || fleet_die "no fleet identity yet — run: agents fleet init"
  mkdir -p "$(sync_root)" "$(sync_conflict_dir)" "$fleet_root/tools" 2>/dev/null
  [ -f "$(sync_state_file)" ] || : > "$(sync_state_file)"
  [ -f "$(sync_exceptions_file)" ] || : > "$(sync_exceptions_file)"
  [ -f "$(sync_auth_optin_file)" ] || : > "$(sync_auth_optin_file)"
  [ -f "$(sync_tools_manifest)" ] || : > "$(sync_tools_manifest)"
}

# --- digests ---------------------------------------------------------------

SYNC_TOMBSTONE='-'
# A peer that is *excepting* a resource is not deleting it. Without a distinct
# marker its silence reads as a tombstone and the originator deletes its own
# copy — a machine-local exception must never destroy the shared setup.
SYNC_EXCEPTED='!'

# The profile existence record also carries an opaque stable ID. It follows
# the profile through replication and directory renames. Same-name profiles
# created independently have distinct IDs and use ordinary conflict resolution.
SYNC_PROFILE_REL='.n2-profile'

sync_digest_file() {  # sync_digest_file <path> -> digest, or the tombstone
  [ -f "$1" ] || { echo "$SYNC_TOMBSTONE"; return 0; }
  shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'
}

# --- addressing ------------------------------------------------------------

# A relpath is only ever interpreted below a slot. Absolute paths, parent
# traversal and empty components are refused here, once, so no caller has to
# remember to check. This runs on both the sending and receiving side: a peer
# is authenticated, not trusted to be well behaved.
sync_safe_relpath() {  # sync_safe_relpath <relpath>
  case $1 in
    '' | /* ) return 1 ;;
    *//* ) return 1 ;;
    '..' | '../'* | *'/..' | *'/../'* ) return 1 ;;
    *'\n'* ) return 1 ;;
  esac
  # A newline or tab inside a relpath would corrupt the line-based manifest.
  case $(printf '%s' "$1" | tr -d '\n\t') in
    "$1") ;;
    *) return 1 ;;
  esac
  return 0
}

sync_valid_class() {
  case $1 in settings|skills|mcp|auth|tools|profile) return 0 ;; *) return 1 ;; esac
}

# An exception is matched against an address field by field, with an *exact*
# string compare on class, profile and vendor. So a field that can never occur
# in an address matches nothing, forever -- and that is the dangerous
# direction: the operator reads `excepted`, believes this machine is now held
# apart from the fleet, and the next pass overwrites the file anyway. These two
# gates refuse exactly the records that are inert by construction, and nothing
# more. In particular a profile that merely does not exist here *yet* is
# accepted: excepting a profile before it arrives is legitimate.
sync_except_name_ok() {  # profile or vendor field of an exception
  case $1 in
    '' | '.' | '..' ) return 1 ;;
    # `|` is the record separator: a field carrying one shifts every field
    # after it, so the stored record means something other than the line the
    # command echoes back. Tab and newline corrupt the store outright.
    *'|'* | */* ) return 1 ;;
  esac
  case $(printf '%s' "$1" | tr -d '\n\t') in "$1") return 0 ;; *) return 1 ;; esac
}

# The trailing glob is the last field, so a `|` inside it is read back intact
# and may legitimately match an addr relpath; `/` is ordinary (skills/*). Only
# the characters that would corrupt the line-based store are refused.
sync_except_glob_ok() {
  [ -n "$1" ] || return 1
  case $(printf '%s' "$1" | tr -d '\n\t') in "$1") return 0 ;; *) return 1 ;; esac
}

sync_addr() { printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4"; }
sync_addr_class()   { printf '%s' "${1%%|*}"; }
sync_addr_profile() { sap=${1#*|}; printf '%s' "${sap%%|*}"; }
sync_addr_vendor() {
  case $1 in
    *'|'*'|'*) sav=${1#*|}; sav=${sav#*|}; printf '%s' "${sav%%|*}" ;;
    *'|'*) ;; *) printf '%s' "$1" ;;
  esac
}
sync_addr_relpath() {
  case $1 in
    *'|'*'|'*'|'*) sar=${1#*|}; sar=${sar#*|}; printf '%s' "${sar#*|}" ;;
    *'|'*) ;; *) printf '%s' "$1" ;;
  esac
}

# The slot dir a resource lives under. Follows an adopted slot symlink to reach
# contents (cmd_adopt points a slot at ~/.claude-profiles/<Name>), but the link
# itself is a local fact and is never replicated.
sync_slot() {  # sync_slot <profile> <vendor>
  [ "$1" = '-' ] && [ "$2" = '-' ] && { echo "$fleet_root/tools"; return 0; }
  [ "$2" = '-' ] && { echo "$root/$1"; return 0; }
  config_dir "$1" "$2"
}

# Absolute path for a resource on this machine, or empty if it would escape.
sync_path() {  # sync_path <class> <profile> <vendor> <relpath>
  sync_safe_relpath "$4" || return 1
  sp_slot=$(sync_slot "$2" "$3") || return 1
  [ -n "$sp_slot" ] || return 1
  printf '%s/%s' "$sp_slot" "$4"
}

# Refuse a path whose *real* location escapes the slot — a symlink inside the
# slot pointing outward would otherwise let a peer write anywhere this user can.
sync_path_contained() {  # sync_path_contained <slot> <path>
  spc_slot=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  spc_dir=$(dirname "$2")
  spc_real=$(cd "$spc_dir" 2>/dev/null && pwd -P) || return 0   # parent absent: will be created inside
  case "$spc_real/" in
    "$spc_slot"/*|"$spc_slot/") return 0 ;;
    *) return 1 ;;
  esac
}

# Follow a symlink chain to the file it finally names. One hop is not enough:
# a link inside the slot can point at a second link inside the slot that points
# out, and checking only the first target would wave that through. A cycle or a
# chain deeper than any honest adopted layout fails closed rather than spinning.
SYNC_LINK_HOPS=32
sync_resolve_chain() {  # sync_resolve_chain <file> -> abspath
  src_p=$1 src_n=0
  case $src_p in /*) ;; *) src_p="$(pwd)/$src_p" ;; esac
  while [ -L "$src_p" ]; do
    [ "$src_n" -lt "$SYNC_LINK_HOPS" ] || return 1
    src_t=$(readlink "$src_p") || return 1
    case $src_t in /*) src_p=$src_t ;; *) src_p="$(dirname "$src_p")/$src_t" ;; esac
    src_n=$((src_n + 1))
  done
  printf '%s' "$src_p"
}

# A file may be *in* the slot and still point out of it. sync_path_contained
# only resolves the parent directory, so a symlinked file passes it; this is
# the check that keeps a planted link from turning into a peer-visible read.
# The whole chain is resolved, so an adopted slot's deliberate links still
# work while a two-hop escape does not.
sync_link_contained() {  # sync_link_contained <slot> <file>
  [ -L "$2" ] || return 0
  slc_slot=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  slc_final=$(sync_resolve_chain "$2") || return 1
  slc_real=$(cd "$(dirname "$slc_final")" 2>/dev/null && pwd -P) || return 1
  case "$slc_real/" in
    "$slc_slot"/*|"$slc_slot/") return 0 ;;
    *) return 1 ;;
  esac
}

# mkdir -p walks through a symlinked ancestor, so a planted directory link
# would let a peer create directories outside the slot *before* the write
# itself could be refused. Validate the deepest ancestor that already exists
# before anything is created.
sync_ancestors_contained() {  # sync_ancestors_contained <slot> <path>
  sac_slot=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  sac_d=$(dirname "$2")
  while [ ! -d "$sac_d" ]; do
    case $sac_d in /|.|'') return 1 ;; esac
    sac_d=$(dirname "$sac_d")
  done
  sac_real=$(cd "$sac_d" 2>/dev/null && pwd -P) || return 1
  case "$sac_real/" in
    "$sac_slot"/*|"$sac_slot/") return 0 ;;
    *) return 1 ;;
  esac
}

# --- what is in scope ------------------------------------------------------

# Machine-local churn. An exclude here is about *noise*; the per-class include
# rules below are the actual allowlist.
sync_excluded_relpath() {
  case $1 in
    .trash/*|*/.trash/*|node_modules/*|*/node_modules/*|__pycache__/*|*/__pycache__/*) return 0 ;;
    projects/*|history*|statsig/*|sessions/*|todos/*|shell-snapshots/*|ide/*) return 0 ;;
  esac
  sync_transient_relpath "$1"
}

# The strictly disposable subset of the above: bytes whose loss costs nobody
# anything. This is deliberately narrower than sync_excluded_relpath, because
# the two questions are different. "Do we replicate it?" excludes session
# transcripts, command history and todo state -- they are machine-local by
# nature and copying them between machines would be wrong. "Is it safe to
# destroy?" does not: a transcript is a person's record of their own work, and
# a profile deletion arriving from a peer that never saw it is the one moment
# where not replicating it turns into losing it. Only this list is passed over
# when weighing a deletion.
sync_transient_relpath() {  # sync_transient_relpath <relpath>
  case $1 in
    *.log|*.lock|*.sock|.DS_Store|*/.DS_Store) return 0 ;;
    cache/*|*/cache/*|tmp/*|*/tmp/*) return 0 ;;
    .git/*|*/.git/*) return 0 ;;
  esac
  return 1
}

# Which vendor, if any, owns a directory sitting directly under a profile.
# Empty means nothing in the product claims it, which makes everything beneath
# it unreplicated by definition.
sync_slot_vendor() {  # sync_slot_vendor <dirname>
  for ssv_v in $N2_VENDORS; do
    [ "$(vendor_slot_name "$ssv_v")" = "$1" ] && { echo "$ssv_v"; return 0; }
  done
  return 1
}

# Class of a relpath inside a vendor slot, or empty when out of scope.
sync_classify() {  # sync_classify <vendor> <relpath>
  # The reserved fleet-level slot holds exactly one replicated file. Anything
  # else that turns up under it is out of scope rather than quietly synced.
  if [ "$1" = '-' ]; then
    # Two fleet-level relpaths, told apart by name. `manifest` is the managed
    # tool list; SYNC_PROFILE_REL is a profile's existence record -- the thing
    # that makes an *empty* profile representable and its deletion a deletion
    # rather than silence. Anything else under a '-' vendor is out of scope.
    [ "$2" = manifest ] && { echo tools; return 0; }
    # The dispatcher's allowed-agent preference. It is a fleet-wide statement
    # about which agents may be chosen, so it replicates like the tool manifest
    # and is excepted per machine through the same mechanism.
    [ "$2" = "$SYNC_AGENTS_REL" ] && { echo tools; return 0; }
    [ "$2" = "$SYNC_PROFILE_REL" ] && { echo profile; return 0; }
    return 0
  fi
  sync_excluded_relpath "$2" && return 0
  case $2 in
    skills/*) echo skills; return 0 ;;
  esac
  case ${2##*/} in
    .credentials.json|auth.json|oauth_creds.json|credentials.json) echo auth; return 0 ;;
    .mcp.json|mcp.json|mcp_servers.json) echo mcp; return 0 ;;
  esac
  case $2 in
    mcp/*) echo mcp; return 0 ;;
    settings.json|settings.local.json|config.toml|config.json|config.yaml|CLAUDE.md|AGENTS.md|GEMINI.md) echo settings; return 0 ;;
    agents/*|commands/*|rules/*|prompts/*|hooks/*) echo settings; return 0 ;;
  esac
  return 0
}

# --- exceptions ------------------------------------------------------------

# Machine-local by design: an exception is a statement about *this* machine, so
# it never syncs and never changes the shared setup for anyone else.
sync_excepted() {  # sync_excepted <addr>
  sync_category_enabled "$(sync_addr_class "$1")" || return 0
  se_f=$(sync_exceptions_file); [ -f "$se_f" ] || return 1
  se_c=$(sync_addr_class "$1") se_p=$(sync_addr_profile "$1")
  se_v=$(sync_addr_vendor "$1") se_r=$(sync_addr_relpath "$1")
  while IFS='|' read -r xc xp xv xr; do
    case $xc in ''|'#'*) continue ;; esac
    [ "$xc" = '*' ] || [ "$xc" = "$se_c" ] || continue
    [ "$xp" = '*' ] || [ "$xp" = "$se_p" ] || continue
    [ "$xv" = '*' ] || [ "$xv" = "$se_v" ] || continue
    [ -z "$xr" ] && xr='*'
    # shellcheck disable=SC2254
    case $se_r in $xr) return 0 ;; esac
  done < "$se_f"
  return 1
}

# Category switches are local exceptions: disabling withholds a resource and
# never announces its deletion to another machine.
sync_category_enabled() { [ ! -f "$(sync_root)/disabled-$1" ]; }

sync_categories() {
  sync_need
  if [ "$#" -gt 0 ]; then
    [ "$#" = 2 ] || fleet_die "usage: agents fleet sync categories [settings|skills|mcp|auth on|off]"
    case $1 in settings|skills|mcp|auth) ;; *) fleet_die "unknown sync category: $1" ;; esac
    case $2 in
      on) rm -f "$(sync_root)/disabled-$1" || return 1 ;;
      off) : > "$(sync_root)/disabled-$1" || return 1 ;;
      *) fleet_die "category state must be on or off" ;;
    esac
  fi
  for cat in settings skills mcp auth; do
    if sync_category_enabled "$cat"; then state=on; else state=off; fi
    printf '%s\t%s\n' "$cat" "$state"
  done
}

# --- auth opt-in -----------------------------------------------------------

# Provider support and evidence are recorded in docs/fleet-authentication.md.
# Partial means the supported file route replicates, with explicit lifecycle or
# storage limits. It does not promise portable Keychain sessions, concurrent
# refresh safety, or provider-side revocation. Unsupported routes refuse opt-in;
# unverified routes state the missing evidence. No provider has a verified full
# fleet authentication lifecycle yet.
sync_auth_support() {  # sync_auth_support <vendor> -> partial|unsupported|unverified
  case $1 in
    codex|claude|grok|muse|cursor) echo partial ;;
    gemini|opencode) echo unsupported ;;
    *) echo unverified ;;
  esac
}

sync_auth_reason() {
  case $1 in
    codex) echo "file snapshots only: auth.json edits replicate with file-conflict detection. Copied credentials passed a receiving-Mac read on 2026-09-25. OpenAI advises against sharing one managed auth.json across concurrent jobs or machines; file conflicts do not coordinate token refresh. N2 has no renewal owner yet. NOT verified: copied-grant renewal or revocation. keyring/ephemeral credentials are not exported" ;;
    opencode) echo "credentials live OUTSIDE the isolated slot: the binary resolves \$XDG_DATA_HOME/opencode/auth.json (else ~/.local/share/opencode/auth.json), while profile isolation only repoints XDG_CONFIG_HOME — so opencode auth is machine-wide, shared by every profile, and nothing under the synced config slot carries it. Opting in would be inert, so it is refused rather than accepted and silently ignored. Lifting this needs XDG_DATA_HOME isolation, a change to the isolation tier" ;;
    claude) echo "profile-scoped keychain logins need an explicit export; file credentials replicate. Copied credentials passed receiving-Mac usage checks on 2026-09-25. Continuous keychain sync, concurrent refresh, and provider-wide logout are not verified" ;;
    cursor) echo "credential-bearing settings and MCP configuration can replicate with opt-in. The CLI login is machine-wide in keychain; CURSOR_CONFIG_DIR does not isolate it and N2 does not export or replace that login" ;;
    grok|muse) echo "profile auth.json is file-portable; cross-machine provider acceptance and refresh behavior are not yet verified" ;;
    gemini) echo "swap-tier isolation: config dir is a source constant, not isolatable per process" ;;
    *) echo "not inspected; absence of evidence is reported as unverified, not assumed portable" ;;
  esac
}

sync_auth_optin() {  # sync_auth_optin <vendor> -> 0 if the operator opted in
  so_f=$(sync_auth_optin_file); [ -f "$so_f" ] || return 1
  grep -qx "$1" "$so_f" 2>/dev/null
}

# --- credential material inside a non-auth file ----------------------------

# Credential material does not only live in a file named auth.json. Claude Code
# reads an `env` block and an `apiKeyHelper` command out of settings.json —
# binary evidence, claude 2.1.277: `strings` yields ANTHROPIC_API_KEY (139
# hits), CLAUDE_CODE_OAUTH_TOKEN (140), apiKeyHelper (103), ANTHROPIC_AUTH_TOKEN
# (64), awsAuthRefresh (25), alongside the settings.json paths that carry them.
# Classifying by path alone would therefore replicate a live token under the
# `settings` class, which is *not* gated by the per-vendor auth opt-in — the
# operator would have shared a credential they never opted into sharing.
#
# The class stays a pure function of the path: an address must not change when a
# file's contents do, or one file would occupy two addresses and the abandoned
# one would read as a deletion. So the *gate* is content-aware instead. A
# settings-class file carrying credential keys needs exactly the opt-in that
# auth.json needs, and is refused on both the sending and the receiving side.
SYNC_SECRET_KEYS='ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|apiKeyHelper|awsAuthRefresh|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|OPENAI_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|OPENROUTER_API_KEY|mcpServers|mcp_servers|mcp'

# An environment-variable name is not the only way a credential is written
# down. A remote MCP server is authenticated with an HTTP header, and the
# header name is fixed by the protocol rather than by the vendor:
#
#   {"mcpServers":{"s":{"url":"https://...","headers":{"Authorization":"Bearer <token>"}}}}
#
# That file is classified `mcp`, which is not gated by the per-vendor auth
# opt-in, and none of the key names above appear in it — so a live bearer token
# replicated to every peer byte-for-byte with auth sharing explicitly off on
# both machines. The operator had refused to share credentials and shared one
# anyway. Header-style and generic credential key names are therefore part of
# the same detection, and the match is case-insensitive because HTTP header
# names are: `authorization` and `Authorization` are the same header.
#
# The snake_case spellings are not enough on their own. An OAuth blob is
# written camelCase far more often than not — Claude Code's own stored grant
# is `{"claudeAiOauth":{"accessToken":...,"refreshToken":...,"expiresAt":...}}`
# — and the same grant pasted into a `settings.json` or `.mcp.json`, neither
# of which is classified `auth` by filename, carried a live token past this
# gate because only `access_token` was listed. `token` itself is here for the
# same reason: it is the single most common key a remote MCP server's config
# stores a bearer credential under. The anchor below is what keeps these from
# over-reading — `maxTokens`, `tokensUsed`, `tokenizer` and `passwordless` all
# put a letter where the anchor needs a quote or `:`/`=`, so none of them
# match.
#
# Hyphen is a third spelling of the same separator, and two providers use it
# for their real authentication header: Azure OpenAI reads `api-key`, and
# Google's generative API reads `x-goog-api-key`. Neither contains a listed
# name as a suffix — `key` is not a name here, and cannot be, because
# `"key":` is an ordinary map key in half the files that sync. So the
# hyphenated spellings are listed explicitly rather than derived by rewriting
# `-` to `_`, which would have broken the `X-Api-Key` alternative it shares a
# character class with. `access-token`, `refresh-token` and `client-secret`
# need no entry of their own: they end in `token` / `secret`, which the anchor
# then reads as the assignment it is. `secret` and `passphrase` are here for
# the same reason `token` is — a bare `"secret":` is not a description of a
# credential, it is one.
SYNC_SECRET_HEADER_KEYS='Authorization|Proxy-Authorization|X-Api-Key|X-Auth-Token|X-Access-Token|api_key|apiKey|access_token|refresh_token|client_secret|secret_key|token|accessToken|refreshToken|idToken|id_token|authToken|auth_token|apiToken|api_token|bearerToken|bearer_token|oauthToken|oauth_token|sessionKey|session_key|clientSecret|privateKey|private_key|password|passwd|api-key|x-goog-api-key|secret|secret-key|private-key|passphrase'

# A JSON key is not stored literally. `"\u0041uthorization"` and
# `"Authorization"` are the same key to every JSON parser, so a grep over the
# raw bytes reads the first one as an unremarkable string and the credential
# ships with auth sharing explicitly off. This was a real bypass: a synthetic
# bearer token under the escaped header name replicated between two peers whose
# auth opt-in files were both empty.
#
# The keys are therefore matched against the *decoded* text. Only the ASCII
# range is decoded -- a key name that spells `Authorization` cannot be written
# with non-ASCII code points, and leaving those escapes literal keeps the
# decoder from inventing bytes. A `\\u0041` (escaped backslash, so literally
# backslash-u-0041 in the string's value) decodes here too; that can only ever
# produce a false *refusal*, which is the safe direction for a credential gate.
# Nothing decoded is printed or returned -- only the exit status escapes.
sync_json_unescape() {  # sync_json_unescape <file> -> text with \uXXXX decoded
  LC_ALL=C awk '
    function hexval(s,   i, c, d, v) {
      v = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        v = v * 16 + d
      }
      return v
    }
    {
      line = $0; out = ""
      while (match(line, /\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]|\\U[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)) {
        out = out substr(line, 1, RSTART - 1)
        hex = substr(line, RSTART + 2, RLENGTH - 2)
        n = hexval(hex)
        if (n >= 32 && n < 127) out = out sprintf("%c", n)
        else out = out substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' "$1" 2>/dev/null
}

# True when the file assigns one of those keys, in JSON (`"K": v`) or TOML/env
# (`K = v`). Only the key name is ever read here; the value is never captured,
# printed, or returned, so this check cannot itself leak the secret.
#
# The match is deliberately *not* line-oriented. JSON permits whitespace --
# newlines included -- between a key string and its colon, so
#
#     { "Authorization"
#       : "Bearer sk-..." }
#
# is one valid member that a per-line grep never sees as an assignment. That
# was a real bypass: a credential file formatted that way replicated to a peer
# that had not opted in, because both the sender and the receiver asked this
# question and both got "no". Every reader is therefore folded to a single
# whitespace-normalised stream first, so the anchor "key name, optional
# closing quote, optional whitespace, assignment" holds across a line break
# the way the format actually defines it. The same fold covers TOML and env
# files, where a newline is not legal between key and `=`; folding them can
# only ever produce a false refusal, which is the safe direction for a gate.
sync_scan_fold() {  # stdin -> every whitespace run collapsed to one space
  LC_ALL=C tr -s '[:space:]' ' '
}

sync_scan_secret_text() {  # sync_scan_secret_text <reader command...>
  # Embedded MCP records have the same credential boundary as mcp.json.
  # TOML tables can carry positional args, URLs and arbitrary env names.
  "$@" | sync_scan_fold |
    LC_ALL=C grep -qiE '\[[^]]*(mcp_servers|mcpServers|mcp)[^]]*\]' && return 0
  "$@" | sync_scan_fold |
    LC_ALL=C grep -qiE "(mcp_servers|mcpServers|mcp)[\"']?[[:space:]]*\\." && return 0
  "$@" | sync_scan_fold |
    LC_ALL=C grep -qE "[\"']?($SYNC_SECRET_KEYS)[\"']?[[:space:]]*[:=]" && return 0
  # Anchored the same way: the key name, an optional closing quote, then the
  # assignment. That anchor is what keeps the broader names from over-reading
  # -- `CLAUDE_CODE_MAX_OUTPUT_TOKENS: 8192` does not match `access_token`, and
  # `"authorizationRequired": true` does not match `Authorization`, because in
  # both the character after the key name is neither a quote nor `:`/`=`.
  #
  # The quote class is both quote characters, not the double quote alone.
  # A TOML key may be written as a literal string -- see
  # https://toml.io/en/v1.0.0#keys -- so
  #
  #     [mcp_servers.test.env]
  #     'OPENAI_API_KEY' = '...'
  #
  # is the same key as the bare spelling to every TOML parser. Reading only
  # the double-quoted form was a real bypass: a codex `config.toml` written
  # that way replicated a synthetic API key to a peer while both machines had
  # auth sharing off, because the sender's scope filter and the receiver's
  # write refusal both ask this question and both answered "no".
  "$@" | sync_scan_fold |
    LC_ALL=C grep -qiE "[\"']?($SYNC_SECRET_HEADER_KEYS)[\"']?[[:space:]]*[:=]" && return 0
  return 1
}

sync_file_carries_secret() {  # sync_file_carries_secret <file>
  [ -f "$1" ] || return 1
  sync_scan_secret_text cat "$1" && return 0
  # Fast path first: the decode only runs when the file actually contains a
  # `\u` escape, so the common case pays one extra grep and no awk.
  LC_ALL=C grep -q '\\[uU]' "$1" 2>/dev/null || return 1
  sync_scan_secret_text sync_json_unescape "$1"
}

# The opt-in a vendor's credential material requires, whatever file it sits in.
sync_secret_shareable() {  # sync_secret_shareable <vendor>
  sync_category_enabled auth || return 1
  sync_auth_optin "$1" || return 1
  [ "$(sync_auth_support "$1")" = unsupported ] && return 1
  return 0
}

# --- state (base digests) --------------------------------------------------

# The base is *per peer*: it is the last state this machine and that peer
# agreed on, not a global "last known" digest. Keying it by address alone was
# a real defect — a second peer that had never seen a resource reported a
# tombstone, which matched the shared base and read as "the peer deleted it",
# so a first sync with a fresh machine deleted local files. A base is a fact
# about a relationship, so it is stored as one.
#
# An address never agreed on with that peer reads as a tombstone, not as an
# empty string. That is what makes "the peer created a file we have never
# seen" a pull instead of a spurious conflict, while two independent creations
# with different bytes still land in the conflict row.
sync_base() {  # sync_base <peer> <addr> -> agreed digest, or the tombstone
  sb_f=$(sync_state_file)
  sb_v=
  [ -f "$sb_f" ] && sb_v=$(awk -F'\t' -v p="$1" -v a="$2" '$1==p && $2==a {print $3}' "$sb_f" | tail -1)
  [ -n "$sb_v" ] || sb_v=$SYNC_TOMBSTONE
  echo "$sb_v"
}

# The state file is a read-modify-write, and a pass against peer B runs happily
# while a pass against peer A is mid-rewrite. Without a lock the second writer
# rebuilds from a snapshot that predates the first and silently drops its line —
# the agreed base for a whole relationship disappears, which reads on the next
# pass as "never seen", i.e. a spurious pull or conflict. mkdir is the only
# atomic test-and-set POSIX sh can count on; a stale lock is broken by age
# rather than by pid, because the writer may be on the far side of a crash.
sync_state_lock() {
  ssl_d="$(sync_root)/state.lock"
  ssl_n=0
  while :; do
    mkdir "$ssl_d" 2>/dev/null && return 0
    ssl_age=$(( $(fleet_now) - $(sync_lock_stamp "$ssl_d") ))
    [ "$ssl_age" -gt 30 ] 2>/dev/null && { rm -rf "$ssl_d"; continue; }
    ssl_n=$((ssl_n + 1))
    [ "$ssl_n" -gt 300 ] && return 1
    sleep 0.05 2>/dev/null || sleep 1
  done
}

sync_lock_stamp() {
  sls=$(stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null)
  case $sls in ''|*[!0-9]*) fleet_now ;; *) echo "$sls" ;; esac
}

sync_state_unlock() { rm -rf "$(sync_root)/state.lock"; }

# The state lock protects the bookkeeping file, not a *resource*. Two responders
# handling concurrent pushes for the same address each read the file, each
# decide against the same agreed base, and the second write lands on top of the
# first: both answer `pull`, no conflict is raised, and one operator's edit is
# gone. Read, decide and write therefore have to happen under one lock held for
# all three steps, keyed by the resource. It is always taken *before* the state
# lock, so the order is resource -> state everywhere and no pair can deadlock.
sync_res_key() {  # sync_res_key <addr> -> filesystem-safe token
  printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
}

# Breaking a *live* holder's lock is worse than waiting: it converts a mutex
# into a 30-second delay after which both parties run the critical section at
# once, which is precisely the lost update the lock exists to stop. The holder
# is always a process on this machine, so liveness is decidable: record the pid
# and only reclaim when that process is actually gone. Age alone remains the
# fallback for the narrow window where the lock directory exists but the pid
# file has not been written yet, and for a pid file left unreadable.
sync_res_lock() {  # sync_res_lock <addr>
  srl_d="$(sync_root)/res.lock"; srl_k=$(sync_res_key "$1")
  [ -n "$srl_k" ] || return 1
  mkdir -p "$srl_d" 2>/dev/null || return 1
  srl_p="$srl_d/$srl_k"; srl_n=0
  while :; do
    if mkdir "$srl_p" 2>/dev/null; then
      echo $$ > "$srl_p/pid" 2>/dev/null
      return 0
    fi
    if sync_lock_holder_alive "$srl_p"; then
      srl_n=$((srl_n + 1))
      # The cap has to outlive the staleness threshold below, otherwise a
      # holder that died mid-write is never recovered from: every waiter would
      # give up before the breaker was reachable, and the resource would be
      # locked out until something else removed the directory.
      [ "$srl_n" -gt 1200 ] && return 1
      sleep 0.05 2>/dev/null || sleep 1
      continue
    fi
    srl_age=$(( $(fleet_now) - $(sync_lock_stamp "$srl_p") ))
    if [ "$srl_age" -gt 30 ] 2>/dev/null; then rm -rf "$srl_p"; continue; fi
    srl_n=$((srl_n + 1))
    [ "$srl_n" -gt 1200 ] && return 1
    sleep 0.05 2>/dev/null || sleep 1
  done
}

# True when the lock directory names a pid that still exists. A missing or
# unreadable pid file is reported as alive so the caller falls through to the
# age check rather than reclaiming a lock that was taken microseconds ago.
sync_lock_holder_alive() {  # sync_lock_holder_alive <lockdir>
  slha=$(cat "$1/pid" 2>/dev/null)
  case $slha in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$slha" 2>/dev/null
}

sync_res_unlock() {  # sync_res_unlock <addr>
  sru_k=$(sync_res_key "$1")
  [ -n "$sru_k" ] && rm -rf "$(sync_root)/res.lock/$sru_k"
  return 0
}

sync_base_set() {  # sync_base_set <peer> <addr> <digest>
  sbs_f=$(sync_state_file); sbs_t="$sbs_f.$$"
  sync_state_lock || return 1
  [ -f "$sbs_f" ] || : > "$sbs_f"
  awk -F'\t' -v p="$1" -v a="$2" '!($1==p && $2==a)' "$sbs_f" > "$sbs_t" 2>/dev/null || : > "$sbs_t"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(fleet_now)" >> "$sbs_t"
  mv "$sbs_t" "$sbs_f"
  sync_state_unlock
}

# --- local manifest --------------------------------------------------------

sync_vendor_list() {
  for v in $N2_VENDORS; do echo "$v"; done
}

# Emit `addr<TAB>digest` for everything in scope on this machine, plus a
# tombstone line for anything we previously agreed on that is now gone —
# a deletion has to be representable or it silently reads as "no change".
# `fleet` is not a profile. It is this machine's own fleet state directory,
# which happens to sit under the profile root and therefore turns up in
# all_profiles. Advertising it would replicate one machine's identity and
# roster to every peer, and a tombstone for it would delete the fleet state on
# the machine that received it. It is refused on both sides.
sync_profile_addressable() {  # sync_profile_addressable <profile>
  [ -n "$1" ] || return 1
  [ "$1" = Default ] && return 1
  [ "$root/$1" = "$fleet_root" ] && return 1
  valid_profile_name "$1" || return 1
  return 0
}

# Assign metadata to a new local profile under the same lock used by sync.
# Existing legacy markers remain unchanged unless initialization is explicit:
# independently migrating each peer would give a shared profile different IDs.
sync_profile_marker() {  # sync_profile_marker <profile> [migrate]
  [ -d "$root/$1" ] || return 1
  spm_addr=$(sync_addr profile "$1" '-' "$SYNC_PROFILE_REL")
  sync_res_lock "$spm_addr" || return 1
  if [ "${2:-}" = migrate ]; then
    /usr/bin/python3 "$scripts_dir/profile-metadata.py" ensure "$root/$1" --migrate-legacy; spm_rc=$?
  else
    /usr/bin/python3 "$scripts_dir/profile-metadata.py" ensure "$root/$1"; spm_rc=$?
  fi
  sync_res_unlock "$spm_addr"
  return "$spm_rc"
}

sync_manifest() {
  sync_ready || return 0
  all_profiles 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    sync_vendor_list | while IFS= read -r v; do
      slot=$(config_dir "$p" "$v") || continue
      [ -d "$slot" ] || continue
      # With credential sharing allowed, no content-based secret scan is needed.
      # Hashing a large skills tree in one process avoids thousands of forks.
      if [ -f "${scripts_dir:-.}/fleet-manifest.py" ] && sync_secret_shareable "$v"; then
        /usr/bin/python3 "${scripts_dir:-.}/fleet-manifest.py" "$slot" "$p" "$v"
        continue
      fi
      # -L so an adopted slot (a symlink) is descended into for contents.
      find -L "$slot" \( -name .trash -o -name node_modules -o -name __pycache__ -o -name .git \) -prune -o -type f -print 2>/dev/null | while IFS= read -r f; do
        rel=${f#"$slot"/}
        [ "$rel" = "$f" ] && continue
        sync_safe_relpath "$rel" || continue
        # find -L descends *through* a symlinked directory, so the file is
        # not itself a link: resolve its parent too or an inside-the-slot
        # directory link exports anything the user can read.
        sync_path_contained "$slot" "$f" || continue
        sync_link_contained "$slot" "$f" || continue
        cls=$(sync_classify "$v" "$rel")
        [ -n "$cls" ] || continue
        # Withheld here means silent here: a resource this machine will not
        # share is not advertised, not even as an exception, because naming it
        # would disclose that the credential exists. What a *peer* must not do
        # is read that silence as a deletion -- see sync_pass.
        if [ "$cls" = auth ] || [ "$cls" = mcp ]; then
          sync_secret_shareable "$v" || continue
        elif sync_file_carries_secret "$f"; then
          # A settings/mcp file carrying a live token is credential material
          # wherever it sits; it leaves this machine only under the same opt-in.
          sync_secret_shareable "$v" || continue
        fi
        printf '%s\t%s\n' "$(sync_addr "$cls" "$p" "$v" "$rel")" "$(sync_digest_file "$f")"
      done
    done
  done
  # Existence records. Default is deliberately omitted: it exists on every
  # machine by definition, so replicating it would be inert, and a tombstone
  # for it could only ever be wrong.
  all_profiles 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = Default ] && continue
    sync_profile_addressable "$p" || continue
    [ -d "$root/$p" ] || continue
    sync_profile_marker "$p" || continue
    printf '%s\t%s\n' "$(sync_addr profile "$p" '-' "$SYNC_PROFILE_REL")" \
      "$(sync_digest_file "$root/$p/$SYNC_PROFILE_REL")"
  done
  # The fleet-level managed-tool manifest, addressed like everything else.
  smtf=$(sync_tools_manifest)
  [ -f "$smtf" ] && printf '%s\t%s\n' "$SYNC_TOOLS_ADDR" "$(sync_digest_file "$smtf")"
  # The dispatcher's allowed-agent preference, same slot, its own address.
  sapf=$(sync_agents_pref)
  [ -f "$sapf" ] && printf '%s\t%s\n' "$SYNC_AGENTS_ADDR" "$(sync_digest_file "$sapf")"
  # Tombstones for agreed resources that no longer exist locally.
  sbf=$(sync_state_file)
  [ -f "$sbf" ] || return 0
  awk -F'\t' '$3!="-" {print $2}' "$sbf" 2>/dev/null | sort -u | while IFS= read -r a; do
    [ -n "$a" ] || continue
    pth=$(sync_path "$(sync_addr_class "$a")" "$(sync_addr_profile "$a")" \
                    "$(sync_addr_vendor "$a")" "$(sync_addr_relpath "$a")") || continue
    [ -f "$pth" ] && continue
    # A missing slot is not a deletion: an adopted profile on an unmounted
    # volume or a renamed profiles root would otherwise tombstone every agreed
    # file and wipe peers. Whole-profile removal travels only through the
    # existence record.
    if [ "$(sync_addr_vendor "$a")" != '-' ]; then
      tsl=$(sync_slot "$(sync_addr_profile "$a")" "$(sync_addr_vendor "$a")") || continue
      [ -d "$tsl" ] || continue
    fi
    printf '%s\t%s\n' "$a" "$SYNC_TOMBSTONE"
  done
}

sync_local_digest() {  # sync_local_digest <addr>
  sld_p=$(sync_path "$(sync_addr_class "$1")" "$(sync_addr_profile "$1")" \
                    "$(sync_addr_vendor "$1")" "$(sync_addr_relpath "$1")") || return 1
  sync_digest_file "$sld_p"
}

# --- the merge decision ----------------------------------------------------

# The entire merge rule. It takes three digests and returns one word. It has no
# access to a timestamp, a machine name or a peer role, which is what makes
# "newest wins" and "primary wins" unrepresentable rather than merely
# discouraged.
sync_decide() {  # sync_decide <base> <local> <remote> -> noop|pull|push|converged|conflict
  sd_b=$1 sd_l=$2 sd_r=$3
  [ "$sd_l" = "$sd_r" ] && { echo converged_or_noop; return 0; }
  if [ "$sd_l" = "$sd_b" ]; then echo pull; return 0; fi
  if [ "$sd_r" = "$sd_b" ]; then echo push; return 0; fi
  echo conflict
}

sync_decide_word() {  # friendlier wrapper used by callers
  sdw=$(sync_decide "$1" "$2" "$3")
  if [ "$sdw" = converged_or_noop ]; then
    [ "$2" = "$1" ] && echo noop || echo converged
  else
    echo "$sdw"
  fi
}

# --- conflicts -------------------------------------------------------------

sync_conflict_id() { printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,12)}'; }

# A conflict id is *only* ever the 12 hex characters sync_conflict_id emits.
# Anything else is not an id, and must never reach a path expression: the id is
# pasted straight into "$(sync_conflict_dir)/$id", and sync_resolve ends with
# `rm -rf` on that directory. Without this gate `resolve ../../../../somewhere
# --local` walks out of the conflict store and deletes an operator directory
# that merely happens to contain a `meta` file carrying an addr= line, while
# reporting `resolved` and exiting 0. `show` has the same shape and would cat
# a meta file from anywhere on disk. Validate once, here, and refuse loudly.
sync_conflict_id_ok() {
  case ${1:-} in
    '') return 1 ;;
    *[!0-9a-f]*) return 1 ;;
  esac
  [ ${#1} -eq 12 ]
}

# Clearing a pin is a two-step move for one reason: `rm -rf` on a directory the
# process cannot unlink deletes the *contents* it can reach and leaves the
# directory behind. That turned a failed resolution into a pin with no meta --
# still listed, no longer carrying an address, and so no longer resolvable by
# any later command. Renaming is atomic: either the pin is gone from the
# conflicts view or nothing moved at all. The staging name is dot-prefixed, so
# the `*` glob in sync_conflicts and the exact-id test in sync_conflict_pinned
# both look straight past it while the caller finishes.
sync_conflict_stage() {  # sync_conflict_stage <dir> -> staged path on stdout
  scg_s="$(dirname "$1")/.resolving-$(basename "$1").$$"
  rm -rf "$scg_s" 2>/dev/null
  mv "$1" "$scg_s" 2>/dev/null || return 1
  printf '%s\n' "$scg_s"
}

sync_conflict_unstage() {  # put a staged pin back exactly as it was
  mv "$1" "$2" 2>/dev/null
}

# Staging is atomic, but the window between the mv and the caller's rm -rf (or
# unstage) is not crash-proof: kill the process mid-resolution and the pin is
# left as `.resolving-<id>.<pid>`. Both read paths look past dot-prefixed names
# by design, so the operator's unresolved conflict silently disappears from
# `fleet sync conflicts` -- it stops being asked about, and the staged bytes sit
# on disk forever as litter no command will ever name.
#
# Recovery sweeps that state before either read path answers. An orphan whose
# owner is gone is put back under its real id when nothing has taken that id in
# the meantime, so an interrupted resolution leaves the pin exactly as it was
# and the operator is asked again. If the id *is* occupied -- a later pass
# re-detected the same divergence and pinned it afresh -- the live pin wins and
# the orphan is discarded, because two directories cannot both be the pin.
#
# An orphan whose owner is still running is left strictly alone: that is a
# resolution in progress on another process, not wreckage.
#
# Honest limit: liveness is `ps -p`, so a recycled pid belonging to an unrelated
# process reads as alive and defers recovery to a later sweep. That errs toward
# leaving the staged bytes in place, never toward deleting a pin, and the next
# sync pass re-detects the divergence regardless.
sync_conflict_recover() {
  for scr_s in "$(sync_conflict_dir)"/.resolving-*; do
    [ -d "$scr_s" ] || continue
    scr_b=${scr_s##*/}
    scr_p=${scr_b##*.}                     # trailing .<pid>
    scr_i=${scr_b#.resolving-}; scr_i=${scr_i%.*}
    case ${scr_p:-} in ''|*[!0-9]*) continue ;; esac
    sync_conflict_id_ok "$scr_i" || continue
    ps -p "$scr_p" >/dev/null 2>&1 && continue
    if [ -e "$(sync_conflict_dir)/$scr_i" ]; then
      rm -rf "$scr_s"
    else
      mv "$scr_s" "$(sync_conflict_dir)/$scr_i" 2>/dev/null || rm -rf "$scr_s"
      fleet_event sync-conflict-recovered "id=$scr_i pid=$scr_p"
    fi
  done
}

sync_conflict_pinned() {  # sync_conflict_pinned <addr>
  sync_conflict_recover
  [ -d "$(sync_conflict_dir)/$(sync_conflict_id "$1")" ]
}

# Retiring a pin without an operator choice is only ever correct when the
# choice has already been made elsewhere against these exact bytes; see the
# fast-forward branch in sync_absorb for the one caller allowed to do it.
sync_conflict_drop() {  # sync_conflict_drop <addr>
  scd_d="$(sync_conflict_dir)/$(sync_conflict_id "$1")"
  [ -d "$scd_d" ] || return 0
  # A pin that cannot be retired must stay whole. The owning peer's write
  # already succeeded; preserving the candidates keeps cleanup recoverable.
  scd_s=$(sync_conflict_stage "$scd_d") || return 1
  rm -rf "$scd_s"
  fleet_event sync-resolved "id=$(sync_conflict_id "$1") choice=peer addr=$(sync_addr_class "$1")|$(sync_addr_profile "$1")|$(sync_addr_vendor "$1")"
}

# Both candidate payloads are preserved. Neither is applied. The resource is
# pinned until the operator chooses, which is also what makes a repeated sync
# pass idempotent instead of re-copying and re-conflicting forever.
# A pinned conflict is not frozen in time: either machine may keep editing the
# resource while it waits for the operator. Candidates recorded at detection go
# stale, and a stale --remote would write bytes the peer no longer has.
sync_conflict_owner() {  # sync_conflict_owner <addr> -> peer id of the pin
  fleet_meta_get_file "$(sync_conflict_dir)/$(sync_conflict_id "$1")/meta" peer 2>/dev/null
}

sync_conflict_stale() {  # sync_conflict_stale <addr> <local-digest> <remote-digest>
  scs_d="$(sync_conflict_dir)/$(sync_conflict_id "$1")"
  [ -f "$scs_d/meta" ] || return 1
  scs_l=$(fleet_meta_get_file "$scs_d/meta" local); [ -n "$scs_l" ] || scs_l=$SYNC_TOMBSTONE
  scs_r=$(fleet_meta_get_file "$scs_d/meta" remote); [ -n "$scs_r" ] || scs_r=$SYNC_TOMBSTONE
  [ "$scs_l" = "$2" ] && [ "$scs_r" = "$3" ] && return 1
  return 0
}

# The fifth argument says what the *absence* of a remote candidate means, and
# it is not optional in spirit: "deleted" is a deletion the peer's manifest
# actually advertised, "unavailable" is a candidate we could not obtain. They
# used to be the same empty file, so a failed fetch became an authoritative
# tombstone and `resolve --remote` deleted the local copy of a file the peer
# still held. Anything that is not an explicitly confirmed deletion is treated
# as unavailable, which blocks --remote instead of destroying data.
# A machine that diverged on a resource someone else already pinned. Its bytes
# are not a candidate for *this* decision, but the operator is entitled to know
# the fleet is three ways apart rather than two.
sync_conflict_note_other() {  # sync_conflict_note_other <addr> <peer> <digest> <state>
  scn_d="$(sync_conflict_dir)/$(sync_conflict_id "$1")"; [ -d "$scn_d" ] || return 1
  scn_o="$scn_d/others"
  { [ -f "$scn_o" ] && awk -F'\t' -v p="$2" '$1!=p' "$scn_o"
    printf '%s\t%s\t%s\n' "$2" "$3" "${4:-present}"; } > "$scn_o.$$" 2>/dev/null &&
    mv "$scn_o.$$" "$scn_o"
  fleet_event sync-conflict-other "id=$(sync_conflict_id "$1") addr=$(sync_addr_class "$1")|$(sync_addr_profile "$1")|$(sync_addr_vendor "$1") peer=$2"
}

sync_conflict_record() {  # sync_conflict_record <addr> <local-path-or-empty> <remote-file-or-empty> <peer> [deleted|present]
  scr_id=$(sync_conflict_id "$1"); scr_d="$(sync_conflict_dir)/$scr_id"
  # Re-recording the same address refreshes one pin rather than piling up a new
  # one per pass, so the operator still sees exactly one decision to make.
  scr_new=1; [ -d "$scr_d" ] && scr_new=
  # ...but only for the peer that raised it. A pin names two candidates, and the
  # remote one belongs to a specific machine. A third peer that merely still
  # holds the pre-divergence bytes used to overwrite it on its next pass, so the
  # operator was shown stale origin bytes and `resolve --remote` "restored" a
  # copy nobody had edited — the peer's real edit was gone. Another peer's
  # divergence is recorded beside the pin instead of replacing it.
  if [ -z "$scr_new" ]; then
    scr_owner=$(fleet_meta_get_file "$scr_d/meta" peer 2>/dev/null)
    if [ -n "$scr_owner" ] && [ "$scr_owner" != "$4" ]; then
      scr_od=$(sync_digest_file "${3:-/nonexistent}")
      scr_os=${5:-present}; [ -n "$3" ] && [ -f "$3" ] && scr_os=present
      sync_conflict_note_other "$1" "$4" "$scr_od" "$scr_os"
      echo "$scr_id"; return 0
    fi
  fi
  mkdir -p "$scr_d" || return 1
  rm -f "$scr_d/local" "$scr_d/local.deleted" "$scr_d/remote" "$scr_d/remote.deleted" "$scr_d/remote.unavailable"
  if [ -n "$2" ] && [ -f "$2" ]; then cp "$2" "$scr_d/local"; else : > "$scr_d/local.deleted"; fi
  if [ -n "$3" ] && [ -f "$3" ]; then
    cp "$3" "$scr_d/remote"; scr_rs=present
  elif [ "${5:-}" = deleted ]; then
    : > "$scr_d/remote.deleted"; scr_rs=deleted
  else
    : > "$scr_d/remote.unavailable"; scr_rs=unavailable
  fi
  {
    printf 'addr=%s\n' "$1"
    printf 'peer=%s\n' "$4"
    printf 'detected_at=%s\n' "$(fleet_now)"
    printf 'local=%s\n' "$(sync_local_digest "$1" 2>/dev/null)"
    printf 'remote=%s\n' "$(sync_digest_file "${3:-/nonexistent}")"
    printf 'remote_state=%s\n' "$scr_rs"
  } > "$scr_d/meta"
  # The address, never the contents: a conflicting auth file must not leak its
  # value into the journal.
  if [ -n "$scr_new" ]; then
    fleet_event sync-conflict "id=$scr_id addr=$(sync_addr_class "$1")|$(sync_addr_profile "$1")|$(sync_addr_vendor "$1") peer=$4"
  else
    fleet_event sync-conflict-refresh "id=$scr_id addr=$(sync_addr_class "$1")|$(sync_addr_profile "$1")|$(sync_addr_vendor "$1") peer=$4"
  fi
  echo "$scr_id"
}

# The scope column is not decoration. A pin outlives the scope it was made in:
# the operator can add an exception (or withdraw an auth opt-in) while the
# conflict sits unresolved, and from then on a sync pass skips the address
# entirely, so nothing re-examines the pin. Without this column the listing
# would show an ordinary conflict for a resource this machine has declared it
# keeps to itself, and `resolve --remote` would quietly honour the peer over
# the exception. Printed for every row so the two states are distinguishable
# rather than one of them being an absence.
sync_conflicts() {
  sync_conflict_recover
  for d in "$(sync_conflict_dir)"/*; do
    [ -d "$d" ] || continue
    scl_s=$(fleet_meta_get_file "$d/meta" remote_state); [ -n "$scl_s" ] || scl_s=present
    scl_a=$(fleet_meta_get_file "$d/meta" addr)
    if [ -n "$scl_a" ] && sync_scope_ok "$scl_a"; then scl_k=in; else scl_k=out; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$d")" "$scl_a" \
      "$(fleet_meta_get_file "$d/meta" peer)" "remote:$scl_s" "scope:$scl_k"
  done
}

# grep -c prints "0" *and* exits 1 when it matches nothing, so `|| echo 0`
# emitted two lines and every `[ "$(sync_conflict_count)" -gt 0 ]` downstream
# died with "integer expression expected".
sync_conflict_count() {
  scc_n=$(sync_conflicts | grep -c . 2>/dev/null) || scc_n=
  case ${scc_n:-} in ''|*[!0-9]*) scc_n=0 ;; esac
  printf '%s\n' "$scc_n"
}

# The same trap, for every other counter. sync_conflict_count was hardened once
# but four more `|| echo 0` sites survived, and each one printed a bare second
# "0" line into `fleet sync status` whenever the file existed and counted zero —
# an unlabelled record in output the tray and --porcelain consumers parse.
# Pass a count through this and a failed or absent grep becomes a single 0.
# Every option below takes a value, and two ways of getting that wrong used to
# slip through: a missing trailing value died with a raw `$2: unbound variable`,
# and an option written without its value swallowed the NEXT option as the
# value. The second is the dangerous one -- `--peer --dry-run` consumed the
# --dry-run, and `--interval --rounds 1` consumed the --rounds and then blamed
# the bare `1`. No peer id, interval or round count begins with `--`, so
# refusing such a value costs nothing and names the option the operator missed.
# Same rule as `tools add`; see docs/fleet-design.md.
sync_needval() {  # sync_needval <option> <argc> <next-arg>
  [ "$2" -ge 2 ] || fleet_die "$1 needs a value"
  case ${3:-} in --*) fleet_die "$1 needs a value, but got the option $3" ;; esac
}

sync_seconds_ok() {  # sync_seconds_ok <option> <value>
  case $2 in ''|*[!0-9]*) fleet_die "$1 takes seconds as a whole number, not: $2" ;; esac
}

sync_num() { case ${1:-} in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$1" ;; esac; }

# --- scope gate (enforced on both sides) -----------------------------------

# Every address crossing the wire passes through here, on the sender *and* the
# receiver. A peer is authenticated by the transport; it is not thereby trusted
# to send a well-formed address, an in-scope class, or a resource this machine
# has declared an exception for.
sync_scope_ok() {  # sync_scope_ok <addr>
  sgo_c=$(sync_addr_class "$1"); sync_valid_class "$sgo_c" || return 1
  sgo_r=$(sync_addr_relpath "$1"); sync_safe_relpath "$sgo_r" || return 1
  sgo_p=$(sync_addr_profile "$1"); [ -n "$sgo_p" ] || return 1
  sgo_v=$(sync_addr_vendor "$1");  [ -n "$sgo_v" ] || return 1
  case $sgo_p in */*|.|..|'') return 1 ;; esac
  case $sgo_v in */*|.|..|'') return 1 ;; esac
  [ "$(sync_classify "$sgo_v" "$sgo_r")" = "$sgo_c" ] || return 1
  # An existence record is an instruction to create or remove a directory named
  # by the peer, so the name is validated exactly as the local CLI validates
  # one. Default is refused in both directions: it is never absent, so a
  # tombstone for it could only destroy vendor slots that should have stayed.
  if [ "$sgo_c" = profile ]; then
    [ "$sgo_v" = '-' ] || return 1
    sync_profile_addressable "$sgo_p" || return 1
  fi
  sync_excepted "$1" && return 1
  # `auth` is credential material by definition, and so is the whole `mcp`
  # class. An MCP server record carries its secrets in shapes the key-name
  # scanner cannot see: `"args": ["--api-key", "SYNTHETIC"]` is a positional
  # value, `postgresql://user:pass@host/db` hides the password inside a URL,
  # a `Cookie` header is a session, and an `env` block may be named anything
  # at all (`GH_PAT`). Gating the class on what a scan happens to recognise
  # was therefore a leak by construction, so the class is gated on the same
  # per-vendor opt-in as auth instead -- in both directions.
  if [ "$sgo_c" = auth ] || [ "$sgo_c" = mcp ]; then
    sync_secret_shareable "$sgo_v" || return 1
  else
    # When the operator already permits this provider's credentials, scanning
    # every byte of every skill cannot further restrict scope. Exceptions and
    # category gates above still apply, including an auth-category opt-out.
    sync_secret_shareable "$sgo_v" && return 0
    # Content-aware: a non-auth file that happens to hold a credential key is
    # gated exactly as auth.json is, on whichever side holds the copy.
    sgo_f=$(sync_path "$sgo_c" "$sgo_p" "$sgo_v" "$sgo_r" 2>/dev/null) || sgo_f=''
    if [ -n "$sgo_f" ] && sync_file_carries_secret "$sgo_f"; then
      sync_secret_shareable "$sgo_v" || return 1
    fi
  fi
  return 0
}

# --- applying a resource ---------------------------------------------------

# Write (or delete) a resource and record the new agreed digest. Containment is
# re-checked against the *resolved* parent, so a symlink planted inside a slot
# cannot redirect the write outside it.
# <expected> is a compare-and-swap: the digest the caller's decision was made
# against. The per-resource lock is what normally keeps the local copy still
# between the read and this write, but a lock broken by age (the writer might
# have crashed) or a caller that forgot to take one must not be able to turn
# into a silent overwrite. Exit 3 means "the disk moved" -- distinct from 1 so
# the caller can re-decide instead of reporting a plain failure.
# Remove a profile the fleet has deleted. An adopted profile directory is a
# symlink to ~/.claude-profiles/<Name>; the link is this machine's local
# decision about where the contents live, so the link is removed and the
# adopted target is left alone -- deleting it would destroy a directory the
# operator adopted from outside the fleet's storage.
# Everything under a profile that this deletion would destroy but nobody here
# agreed to lose: a machine-specific exception, an unresolved pin, an edit made
# on this machine that the deleting peer never saw, and any file the fleet does
# not replicate at all -- machine-only data, or a credential this machine keeps
# to itself. A tombstone for the existence record is a recursive rm, so it is
# weighed against this list *before* anything is unlinked. Lines are
# `<reason> <addr-or-path>`; an empty output means the subtree is exactly what
# the peer last saw and losing it loses nothing.
sync_profile_blockers() {  # sync_profile_blockers <profile> <peer>
  spb_p=$1 spb_peer=${2:-}
  sync_profile_addressable "$spb_p" || return 0
  [ -n "$spb_peer" ] || return 0
  spb_dir="$root/$spb_p"
  [ -d "$spb_dir" ] || return 0
  # Honouring the deletion is `rm -rf` on the whole profile directory, so the
  # whole directory is what has to be weighed -- not only the vendor slots.
  # A file at the profile root, or under a directory no vendor claims, is
  # replicated by nobody, which makes it the *most* local thing in here rather
  # than something to pass over in silence.
  find -L "$spb_dir" -type f 2>/dev/null | while IFS= read -r spb_f; do
    spb_rel=${spb_f#"$spb_dir"/}
    [ "$spb_rel" = "$spb_f" ] && continue
    sync_transient_relpath "$spb_rel" && continue
    case $spb_rel in .n2sync.*|*/.n2sync.*) continue ;; esac
    # The existence record is the thing being deleted, not a casualty of it.
    [ "$spb_rel" = "$SYNC_PROFILE_REL" ] && continue
    spb_top=${spb_rel%%/*}
    spb_v=$(sync_slot_vendor "$spb_top" 2>/dev/null) || spb_v=''
    if [ -z "$spb_v" ] || [ "$spb_top" = "$spb_rel" ]; then
      # Profile-root files and unclaimed directories: no vendor, no class, no
      # peer has ever seen these bytes. Report the path as-is; it is not an
      # address because nothing addressable covers it.
      printf 'local-only %s\n' "$spb_rel"; continue
    fi
    spb_rel=${spb_rel#*/}
    if ! sync_safe_relpath "$spb_rel"; then
      printf 'local-only %s/%s\n' "$spb_v" "$spb_rel"; continue
    fi
    # Empty class covers both "the fleet does not replicate this kind of file"
    # (session history, todos, projects) and "we do not recognise it at all".
    # Either way nobody agreed to lose it.
    spb_c=$(sync_classify "$spb_v" "$spb_rel")
    if [ -z "$spb_c" ]; then
      printf 'local-only %s/%s\n' "$spb_v" "$spb_rel"; continue
    fi
    spb_a=$(sync_addr "$spb_c" "$spb_p" "$spb_v" "$spb_rel")
    if sync_excepted "$spb_a"; then printf 'excepted %s\n' "$spb_a"; continue; fi
    if sync_conflict_pinned "$spb_a"; then printf 'conflict %s\n' "$spb_a"; continue; fi
    # An auth file this machine never opted into sharing is not in any peer's
    # base, so the comparison below already catches it; saying so by name
    # would be a disclosure, so it is reported as unsynced like anything else.
    spb_l=$(sync_digest_file "$spb_f")
    spb_b=$(sync_base "$spb_peer" "$spb_a")
    [ "$spb_l" = "$spb_b" ] || printf 'unsynced %s\n' "$spb_a"
  done
}

# Remove a profile the fleet has deleted. An adopted profile directory is a
# symlink to ~/.claude-profiles/<Name>; the link is this machine's local
# decision about where the contents live, so the link is removed and the
# adopted target is left alone -- deleting it would destroy a directory the
# operator adopted from outside the fleet's storage.
#
# Exit 2 means "blocked": the subtree still holds something this machine was
# never asked to give up. Nothing is unlinked in that case; the caller turns it
# into a visible conflict, and an operator who really does want the profile
# gone resolves that conflict, which calls back here with <force>.
sync_profile_remove() {  # sync_profile_remove <profile> [peer] [force]
  sync_profile_addressable "$1" || return 1
  spr_d="$root/$1"
  [ -e "$spr_d" ] || [ -L "$spr_d" ] || return 0
  # A profile that is live for a vendor here is not torn out from under a
  # running agent. The local CLI refuses the same deletion; sync reports the
  # failure rather than converging on a lie.
  for spr_v in $N2_VENDORS; do
    [ "$(active_profile "$spr_v" 2>/dev/null)" = "$1" ] && return 1
  done
  # An adopted profile is a symlink to storage outside the fleet's root, so
  # honouring the deletion unlinks it and destroys no bytes at all. The blocker
  # check below exists to prevent data loss; there is none to prevent here, and
  # applying it would wedge every adopted profile the fleet ever deletes.
  if [ -L "$spr_d" ]; then rm -f "$spr_d" 2>/dev/null || return 1; return 0; fi
  if [ "${3:-}" != force ]; then
    spr_bl=$(sync_profile_blockers "$1" "${2:-}" 2>/dev/null)
    [ -n "$spr_bl" ] && return 2
  fi
  spr_real=$(cd "$spr_d" 2>/dev/null && pwd -P) || return 1
  spr_rootreal=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  [ "$spr_real" = "$spr_rootreal/$1" ] || return 1
  rm -rf "$spr_d" 2>/dev/null || return 1
  return 0
}

sync_write() {  # sync_write <addr> <srcfile|''=delete> [expected-digest] [peer] [force]
  sw_c=$(sync_addr_class "$1") sw_p=$(sync_addr_profile "$1")
  sw_v=$(sync_addr_vendor "$1") sw_r=$(sync_addr_relpath "$1")
  sw_slot=$(sync_slot "$sw_p" "$sw_v") || return 1
  sw_path=$(sync_path "$sw_c" "$sw_p" "$sw_v" "$sw_r") || return 1
  # ${3:-} not $3: the expected digest is optional and the shell runs under
  # `set -u`, so an absent third argument must read as empty, not abort.
  sw_exp=${3:-}
  if [ -n "$sw_exp" ]; then
    sw_now=$(sync_local_digest "$1" 2>/dev/null)
    [ -n "$sw_now" ] || sw_now=$SYNC_TOMBSTONE
    [ "$sw_now" = "$sw_exp" ] || return 3
  fi
  if [ -z "$2" ]; then
    # A tombstone for an existence record is "this profile is gone from the
    # fleet", which means the vendor slots go with it -- deleting only the
    # marker would leave the directory behind and the profile would still be
    # listed. This is the one place sync removes a tree, so it is fenced: the
    # name is a profile name, it is not Default, and the directory it resolves
    # to sits directly under the profile root.
    if [ "$sw_c" = profile ]; then
      # Exit 4 is "blocked, nothing removed" -- distinct from 1 (failed) and 3
      # (the disk moved) so the caller can show the operator the choice instead
      # of reporting a plain failure or, worse, converging on the deletion.
      sync_profile_remove "$sw_p" "${4:-}" "${5:-}"; sw_prc=$?
      [ "$sw_prc" = 0 ] && return 0
      [ "$sw_prc" = 2 ] && return 4
      return 1
    fi
    [ -d "$sw_slot" ] || return 0
    sync_path_contained "$sw_slot" "$sw_path" || return 1
    rm -f "$sw_path" 2>/dev/null || return 1
    return 0
  fi
  if [ "$sw_c" = profile ]; then
    /usr/bin/python3 "$scripts_dir/profile-metadata.py" validate "$2" || return 1
  fi
  # Last gate before the bytes land. sync_scope_ok inspects the *local* copy,
  # which may not exist yet on a first pull, so the arriving payload is checked
  # too: a peer cannot deliver a credential this machine never opted into by
  # hiding it in a settings file.
  case $sw_c in
    auth|mcp) sync_secret_shareable "$sw_v" || return 1 ;;
    *) if sync_file_carries_secret "$2"; then
         sync_secret_shareable "$sw_v" || return 1
       fi ;;
  esac
  # A child arriving before its profile marker must not create a directory
  # which a later manifest mistakes for a new local profile. Older senders can
  # retry this child after their marker arrives; Default remains machine-local.
  if [ "$sw_v" != '-' ] && [ "$sw_p" != Default ]; then
    /usr/bin/python3 "$scripts_dir/profile-metadata.py" validate "$root/$sw_p/$SYNC_PROFILE_REL" || return 1
  fi
  mkdir -p "$sw_slot" 2>/dev/null || return 1
  sync_ancestors_contained "$sw_slot" "$sw_path" || return 1
  mkdir -p "$(dirname "$sw_path")" 2>/dev/null || return 1
  sync_path_contained "$sw_slot" "$sw_path" || return 1
  sync_link_contained "$sw_slot" "$sw_path" || return 1
  # Same-directory temp + mv: a reader never sees a half-written credential,
  # and the file never transits a world-readable /tmp.
  sw_tmp="$(dirname "$sw_path")/.n2sync.$$"
  cp "$2" "$sw_tmp" 2>/dev/null || return 1
  # cp to a fresh temp takes the umask, so an existing file keeps its own mode
  # (hooks stay executable, a 600 settings file stays private). A new file
  # carrying a secret is created private.
  if [ -f "$sw_path" ]; then
    sw_mode=$(stat -f '%Lp' "$sw_path" 2>/dev/null || stat -c '%a' "$sw_path" 2>/dev/null)
    [ -n "$sw_mode" ] && chmod "$sw_mode" "$sw_tmp" 2>/dev/null
  elif sync_file_carries_secret "$sw_tmp"; then
    chmod 600 "$sw_tmp" 2>/dev/null || true
  elif [ "$(head -c 2 "$sw_tmp" 2>/dev/null)" = '#!' ]; then
    # The wire carries bytes, not modes; a script arriving for the first time
    # (hook, skill helper) is made runnable rather than landing inert.
    chmod +x "$sw_tmp" 2>/dev/null || true
  fi
  case $sw_c in auth) chmod 600 "$sw_tmp" 2>/dev/null || true ;; esac
  mv "$sw_tmp" "$sw_path" 2>/dev/null || { rm -f "$sw_tmp"; return 1; }
  return 0
}

# Decide and act on one incoming resource. Used by the receiver of a push and
# by the initiator of a pull, so both directions obey the same table.
sync_absorb() {  # sync_absorb <addr> <remote-file|''> <remote-digest> <peer> [sender-base] -> word
  # Everything below reads the local copy, decides from what it read, and then
  # writes. Serialise the whole transaction per resource: without this, two
  # concurrent pushes carrying different edits both see the agreed base, both
  # say `pull`, and the later write silently discards the earlier one.
  sync_res_lock "$1" || return 1
  sync_absorb_locked "$@"; sab_rc=$?
  sync_res_unlock "$1"
  return $sab_rc
}

sync_absorb_locked() {
  sa_b=$(sync_base "$4" "$1"); sa_l=$(sync_local_digest "$1" 2>/dev/null) || return 1
  [ -n "$sa_l" ] || sa_l=$SYNC_TOMBSTONE
  sa_w=$(sync_decide_word "$sa_b" "$sa_l" "$3")
  # An operator resolves a conflict on one machine, and the decision has to
  # travel. It cannot travel through this machine's own bookkeeping: our agreed
  # base with the sender predates our own edit, so the table says "both sides
  # changed" and we would pin a second, inverted copy of a conflict the
  # operator has already settled -- and answer the sender with a word that
  # leaves the resource stuck forever.
  # A sender declares the base it is pushing from. When that declared base is
  # byte-for-byte what we hold right now, the sender weighed *our* contents
  # against its own before it chose, so taking its version discards nothing we
  # have that it had not already seen. An edit made here after the sender
  # looked moves sa_l off the declared base, and then none of this applies:
  # the conflict stands and is pinned as before.
  sa_retire=0
  sa_sb=${5:-}  # optional: absent under `set -u` must read as empty
  if [ -n "$sa_sb" ] && [ "$sa_sb" = "$sa_l" ] && [ "$sa_l" != "$3" ]; then
    # ...and only for the pin this sender itself raised. A pin names the peer
    # whose candidate the operator is being asked about. A *different* peer
    # that happens to be pushing from our current bytes has weighed its own
    # copy against ours, which says nothing about the candidate a third
    # machine is waiting on: retiring that pin here would answer a question
    # the operator never answered and discard the very bytes it preserved.
    # An unpinned resource has no such owner, so a plain fast-forward still
    # applies.
    sa_own=; sync_conflict_pinned "$1" && sa_own=$(sync_conflict_owner "$1")
    if [ -z "$sa_own" ] || [ "$sa_own" = "$4" ]; then
      case $sa_w in
        push|conflict)
          sa_w=pull
          [ -z "$sa_own" ] || sa_retire=1 ;;
      esac
    fi
  fi
  # A pin is a statement about the *resource*, not about the peer that caused
  # it. Without this, a third machine whose own base happens to agree with ours
  # pushes straight through an unresolved conflict and overwrites the very
  # candidate the operator was asked to choose between. The pin outranks the
  # decision table: nothing lands until the operator resolves it.
  if [ "$sa_w" = pull ] && [ "$sa_retire" != 1 ] && sync_conflict_pinned "$1"; then
    if sync_conflict_stale "$1" "$sa_l" "$3"; then
      sa_lp=$(sync_path "$(sync_addr_class "$1")" "$(sync_addr_profile "$1")" \
                        "$(sync_addr_vendor "$1")" "$(sync_addr_relpath "$1")" 2>/dev/null)
      sa_rs=present; [ "$3" = "$SYNC_TOMBSTONE" ] && sa_rs=deleted
      sync_conflict_record "$1" "$sa_lp" "$2" "$4" "$sa_rs" >/dev/null
    fi
    echo pinned; return 0
  fi
  case $sa_w in
    noop) ;;
    converged) sync_base_set "$4" "$1" "$sa_l" ;;
    push) ;;                       # nothing to apply here; the peer pulls it
    pull)
      # The decision above was made against sa_l. Write only if that is still
      # what is on disk; if it moved, the edit that landed is a real divergence
      # the operator has to see, never something to overwrite quietly.
      if [ "$3" = "$SYNC_TOMBSTONE" ]; then sync_write "$1" '' "$sa_l" "$4"
      else sync_write "$1" "$2" "$sa_l"; fi
      sa_rc=$?
      # The peer deleted a profile whose subtree still holds work this machine
      # never handed over. Nothing was removed; the operator is shown the
      # deletion as a choice, with the local copy intact behind it.
      if [ "$sa_rc" = 4 ]; then
        sync_conflict_pinned "$1" || {
          sa_lp=$(sync_path "$(sync_addr_class "$1")" "$(sync_addr_profile "$1")" \
                            "$(sync_addr_vendor "$1")" "$(sync_addr_relpath "$1")" 2>/dev/null)
          sync_conflict_record "$1" "$sa_lp" '' "$4" deleted >/dev/null; }
        echo conflict; return 0
      fi
      if [ "$sa_rc" = 3 ]; then
        sa_rs=present; [ "$3" = "$SYNC_TOMBSTONE" ] && sa_rs=deleted
        sync_pull_raced "$1" "$sa_b" "$3" "$4" "$2" "$sa_rs" >/dev/null
        echo conflict; return 0
      fi
      [ "$sa_rc" = 0 ] || return 1
      # Retire only after the write succeeds. Validation or filesystem failure
      # must leave the operator's pending candidates available for recovery.
      [ "$sa_retire" != 1 ] || sync_conflict_drop "$1"
      sync_base_set "$4" "$1" "$3"
      fleet_event sync-apply "addr=$(sync_addr_class "$1")|$(sync_addr_profile "$1")|$(sync_addr_vendor "$1") peer=$4" ;;
    conflict)
      sync_conflict_pinned "$1" || {
        sa_lp=$(sync_path "$(sync_addr_class "$1")" "$(sync_addr_profile "$1")" \
                          "$(sync_addr_vendor "$1")" "$(sync_addr_relpath "$1")" 2>/dev/null)
        sa_rs=present; [ "$3" = "$SYNC_TOMBSTONE" ] && sa_rs=deleted
        sync_conflict_record "$1" "$sa_lp" "$2" "$4" "$sa_rs" >/dev/null; } ;;
  esac
  echo "$sa_w"
}

# --- wire verbs ------------------------------------------------------------

# The responder answers with its own in-scope view. Its exceptions and its auth
# opt-in apply to what it is willing to advertise, which is why an exception is
# honoured in both directions without either side having to trust the other.
fleet_handle_sync_manifest() {
  sync_ready || sync_init
  sync_manifest | while IFS="$(printf '\t')" read -r a d; do
    [ -n "$a" ] || continue
    if ! sync_scope_ok "$a"; then
      # An exception is announced, not hidden. Everything else out of scope
      # (bad class, unsafe path, auth not opted in) stays unmentioned.
      sync_excepted "$a" && printf '%s\t%s\n' "$a" "$SYNC_EXCEPTED"
      continue
    fi
    printf '%s\t%s\n' "$a" "$d"
  done > "$3/out"
  fleet_ok "$3/out"
}

fleet_handle_sync_get() {
  sg_a=$(fleet_meta_get_file "$2" addr)
  [ -n "$sg_a" ] || { echo "ERR sync-bad-addr"; return 1; }
  sync_scope_ok "$sg_a" || { echo "ERR sync-out-of-scope"; return 1; }
  sg_p=$(sync_path "$(sync_addr_class "$sg_a")" "$(sync_addr_profile "$sg_a")" \
                   "$(sync_addr_vendor "$sg_a")" "$(sync_addr_relpath "$sg_a")") ||
    { echo "ERR sync-unsafe-path"; return 1; }
  sg_slot=$(sync_slot "$(sync_addr_profile "$sg_a")" "$(sync_addr_vendor "$sg_a")")
  [ -d "$sg_slot" ] && { sync_path_contained "$sg_slot" "$sg_p" || { echo "ERR sync-escapes-slot"; return 1; }; }
  sync_link_contained "$sg_slot" "$sg_p" || { echo "ERR sync-escapes-slot"; return 1; }
  [ -f "$sg_p" ] || { echo "ERR sync-absent"; return 1; }
  fleet_ok "$sg_p"
}

# payload: addr=<addr>\ndigest=<d>\n--\n<base64 body, absent for a tombstone>
fleet_handle_sync_put() {
  sync_ready || sync_init
  sp_a=$(fleet_header "$2" addr); sp_d=$(fleet_header "$2" digest)
  # The base the sender is pushing from. A peer may only ever declare a digest
  # it actually saw us advertise, so this widens nothing: it lets a resolution
  # made against our published bytes land, and lets nothing else land.
  sp_b=$(fleet_header "$2" base)
  [ -n "$sp_a" ] && [ -n "$sp_d" ] || { echo "ERR sync-bad-put"; return 1; }
  sync_scope_ok "$sp_a" || { echo "ERR sync-out-of-scope"; return 1; }
  sp_body=
  if [ "$sp_d" != "$SYNC_TOMBSTONE" ]; then
    sp_body="$3/sync-in"
    awk 'f{print} /^--$/{f=1}' "$2" | base64 -d > "$sp_body" 2>/dev/null ||
      { echo "ERR sync-undecodable"; return 1; }
    # The sender's claim about its own bytes is checked, not believed.
    [ "$(sync_digest_file "$sp_body")" = "$sp_d" ] || { echo "ERR sync-digest-mismatch"; return 1; }
  fi
  sp_w=$(sync_absorb "$sp_a" "$sp_body" "$sp_d" "$1" "$sp_b") || { echo "ERR sync-apply-failed"; return 1; }
  # `push` is a routine word in a pull pass, but inside a *put* it means the
  # sender is pushing from a base this machine has already moved past: both
  # sides changed since they last agreed. That is a conflict, and it is pinned
  # here rather than answered with a word that leaves the resource silently
  # stuck forever.
  if [ "$sp_w" = push ]; then
    sync_conflict_pinned "$sp_a" || {
      sp_lp=$(sync_path "$(sync_addr_class "$sp_a")" "$(sync_addr_profile "$sp_a")" \
                        "$(sync_addr_vendor "$sp_a")" "$(sync_addr_relpath "$sp_a")" 2>/dev/null)
      sp_rs=present; [ "$sp_d" = "$SYNC_TOMBSTONE" ] && sp_rs=deleted
      sync_conflict_record "$sp_a" "$sp_lp" "$sp_body" "$1" "$sp_rs" >/dev/null; }
    sp_w=conflict
  fi
  # A manifest that arrives as a push is the same operator designation as one
  # this machine pulled, so it applies on arrival rather than waiting for the
  # receiver to happen to run a pass. Authorization is still the manifest and
  # nothing else, and sync_tools_apply keeps the active-task deferral rule.
  case $sp_w in
    # `|| true`: a failing installer is reported by `tools apply`'s own exit
    # status, but it must not abort this handler under `set -e` and leave the
    # sender staring at a protocol error for a delivery that actually landed.
    pull|deleted) sync_addr_is_tools "$sp_a" && { sync_tools_apply >/dev/null 2>&1 || true; } ;;
  esac
  printf '%s\n' "$sp_w" > "$3/out"
  fleet_ok "$3/out"
}

# --- a sync pass -----------------------------------------------------------

sync_remote_manifest() {  # <peer> -> addr\tdigest lines
  fleet_call "$1" sync-manifest 2>/dev/null
}

sync_push_one() {  # <peer> <addr> <digest> -> peer's word, or empty on failure
  spo_t=$(mktemp -d "${TMPDIR:-/tmp}/n2sput.XXXXXX") || return 1
  {
    printf 'addr=%s\ndigest=%s\nbase=%s\n--\n' "$2" "$3" "$(sync_base "$1" "$2")"
    if [ "$3" != "$SYNC_TOMBSTONE" ]; then
      spo_p=$(sync_path "$(sync_addr_class "$2")" "$(sync_addr_profile "$2")" \
                        "$(sync_addr_vendor "$2")" "$(sync_addr_relpath "$2")")
      spo_slot=$(sync_slot "$(sync_addr_profile "$2")" "$(sync_addr_vendor "$2")")
      sync_path_contained "$spo_slot" "$spo_p" || return 1
      sync_link_contained "$spo_slot" "$spo_p" || return 1
      base64 < "$spo_p"
    fi
  } > "$spo_t/p" 2>/dev/null
  spo_o=$(fleet_call "$1" sync-put "$spo_t/p" 2>/dev/null); spo_r=$?
  rm -rf "$spo_t"
  [ "$spo_r" = 0 ] || return 1
  printf '%s' "$spo_o" | head -1
}

# One pass against one peer. Emits `word<TAB>addr` lines so the CLI, the tests
# and the native UI all read the same record of what a pass actually did.
# Fetch the peer's copy of one address for the conflict record, and believe it
# only if its bytes hash to the digest the peer advertised. Prints the state the
# candidate should be recorded with; the body lands in <outfile> when present.
sync_fetch_candidate() {  # sync_fetch_candidate <peer> <addr> <digest> <outfile> -> present|deleted|unavailable
  [ "$3" != "$SYNC_TOMBSTONE" ] || { echo deleted; return 0; }
  sfc_req="$4.req"
  printf 'addr=%s\n' "$2" > "$sfc_req" 2>/dev/null || { echo unavailable; return 0; }
  if fleet_call "$1" sync-get "$sfc_req" > "$4" 2>/dev/null &&
     [ "$(sync_digest_file "$4")" = "$3" ]; then
    rm -f "$sfc_req"; echo present; return 0
  fi
  # Not knowing is not agreement, and it is certainly not a deletion.
  rm -f "$sfc_req" "$4"; echo unavailable; return 0
}

# A pass decides from a manifest snapshot but applies some time later, with a
# peer round trip in between. These two keep that gap from turning into a lost
# update: nothing is written over a local copy that moved after it was read.

# Did the local copy stay exactly as the decision saw it?
sync_pull_still_current() {  # sync_pull_still_current <addr> <digest-at-decision>
  [ "$(sync_local_digest "$1" 2>/dev/null)" = "$2" ]
}

# It moved. Re-decide against what is on disk *now* and act on that, never on
# the stale word. Only two answers are reachable here (the decision that got us
# this far means local equalled base and remote did not): the local edit
# happens to match the remote, which is convergence, or it does not, which is a
# conflict the operator has to see. Neither overwrites the new local bytes.
sync_pull_raced() {  # sync_pull_raced <addr> <base> <remote> <peer> <remote-body|''> <present|deleted>
  spr_l=$(sync_local_digest "$1" 2>/dev/null)
  case $(sync_decide_word "$2" "$spr_l" "$3") in
    noop) printf 'noop\t%s\n' "$1" ;;
    converged) sync_base_set "$4" "$1" "$spr_l"; printf 'converged\t%s\n' "$1" ;;
    *)
      if ! sync_conflict_pinned "$1"; then
        spr_lp=$(sync_path "$(sync_addr_class "$1")" "$(sync_addr_profile "$1")" \
                           "$(sync_addr_vendor "$1")" "$(sync_addr_relpath "$1")" 2>/dev/null)
        spr_cf=; [ "$6" = present ] && spr_cf=$5
        sync_conflict_record "$1" "$spr_lp" "$spr_cf" "$4" "$6" >/dev/null
      fi
      printf 'conflict\t%s\n' "$1" ;;
  esac
}

sync_pass_peer() {  # sync_pass_peer <peer> [dryrun]
  spp_peer=$1 spp_dry=${2:-} spp_tools=
  spp_t=$(mktemp -d "${TMPDIR:-/tmp}/n2spass.XXXXXX") || return 1
  if ! sync_remote_manifest "$spp_peer" > "$spp_t/remote" 2>/dev/null; then
    printf 'unreachable\t%s\n' "$spp_peer"; rm -rf "$spp_t"; return 2
  fi
  sync_manifest > "$spp_t/local" 2>/dev/null
  # Establish live profile identity before any child resource. Profile
  # tombstones follow child removals so existing deletion blockers still apply.
  awk -F'\t' '{seen[$1]=1; if($2=="-") deleted[$1]=1}
    END {for(a in seen) print (a ~ /^profile[|]/ ? (deleted[a] ? 2 : 0) : 1) "\t" a}' \
    "$spp_t/local" "$spp_t/remote" | sort | cut -f2- > "$spp_t/addrs"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    sync_scope_ok "$a" || { printf 'skipped\t%s\n' "$a"; continue; }
    l=$(awk -F'\t' -v k="$a" '$1==k{print $2}' "$spp_t/local" | tail -1)
    r=$(awk -F'\t' -v k="$a" '$1==k{print $2}' "$spp_t/remote" | tail -1)
    if [ -z "$l" ] || [ -z "$r" ]; then
      if [ "$(sync_base "$spp_peer" "$a")" != "$SYNC_TOMBSTONE" ]; then
        # Agreed on once, advertised by neither side now, and no tombstone was
        # raised. Silence is not a deletion. Reading it as one deleted a
        # credential the other machine still held, the moment its owner turned
        # auth sharing off. Both copies stay; the base stays where it was.
        printf 'excepted\t%s\n' "$a"; continue
      fi
      [ -n "$l" ] || l=$SYNC_TOMBSTONE
      [ -n "$r" ] || r=$SYNC_TOMBSTONE
    fi
    if sync_conflict_pinned "$a"; then
      # Still pinned, still the operator's call — but keep the two candidates
      # honest while it waits. Nothing is applied here; only what the operator
      # will be shown is brought up to date.
      if [ "$r" != "$SYNC_EXCEPTED" ] && [ -z "$spp_dry" ] &&
         [ "$(sync_conflict_owner "$a")" != "$spp_peer" ] && [ "$r" != "$l" ]; then
        # Not the peer that raised the pin: its bytes are recorded beside the
        # decision, never in place of the candidate being decided.
        sync_conflict_note_other "$a" "$spp_peer" "$r" \
          "$([ "$r" = "$SYNC_TOMBSTONE" ] && echo deleted || echo present)"
      fi
      if [ "$r" != "$SYNC_EXCEPTED" ] && [ -z "$spp_dry" ] &&
         [ "$(sync_conflict_owner "$a")" = "$spp_peer" ] &&
         sync_conflict_stale "$a" "$l" "$r"; then
        rs=$(sync_fetch_candidate "$spp_peer" "$a" "$r" "$spp_t/body")
        cf=; [ "$rs" = present ] && cf=$spp_t/body
        lp=$(sync_path "$(sync_addr_class "$a")" "$(sync_addr_profile "$a")" \
                       "$(sync_addr_vendor "$a")" "$(sync_addr_relpath "$a")" 2>/dev/null)
        sync_conflict_record "$a" "$lp" "$cf" "$spp_peer" "$rs" >/dev/null
      fi
      printf 'pinned\t%s\n' "$a"; continue
    fi
    if [ "$r" = "$SYNC_EXCEPTED" ]; then
      # The peer keeps its own copy (or lack of one) and we keep ours. The
      # agreed base is deliberately left alone: nothing was exchanged.
      printf 'excepted\t%s\n' "$a"; continue
    fi
    b=$(sync_base "$spp_peer" "$a")
    w=$(sync_decide_word "$b" "$l" "$r")
    if [ -n "$spp_dry" ]; then printf '%s\t%s\n' "$w" "$a"; continue; fi
    case $w in
      noop) printf 'noop\t%s\n' "$a" ;;
      converged) sync_base_set "$spp_peer" "$a" "$l"; printf 'converged\t%s\n' "$a" ;;
      pull)
        # Hold the resource across re-read, decision and write, for the same
        # reason sync_absorb does: an incoming push for this address must not
        # interleave with this pass's apply.
        sync_res_lock "$a" || { printf 'failed\t%s\n' "$a"; continue; }
        if [ "$r" = "$SYNC_TOMBSTONE" ]; then
          # The manifest digest is a snapshot. Between taking it and writing,
          # the operator (or an overlapping pass) may have edited this file,
          # and applying a deletion decided against bytes that no longer exist
          # would destroy an edit nobody was ever shown. Re-read first.
          if ! sync_pull_still_current "$a" "$l"; then
            sync_pull_raced "$a" "$b" "$r" "$spp_peer" '' deleted
            sync_res_unlock "$a"; continue
          fi
          sync_write "$a" '' '' "$spp_peer"; spp_wrc=$?
          if [ "$spp_wrc" = 0 ]; then
            sync_base_set "$spp_peer" "$a" "$SYNC_TOMBSTONE"; printf 'deleted\t%s\n' "$a"
            sync_addr_is_tools "$a" && spp_tools=1
          elif [ "$spp_wrc" = 4 ]; then
            # Blocked: the profile still holds excepted, pinned, unsynced or
            # machine-only files. The base stays where it was, so the deletion
            # is offered again next pass rather than being forgotten.
            if ! sync_conflict_pinned "$a"; then
              spp_lp=$(sync_path "$(sync_addr_class "$a")" "$(sync_addr_profile "$a")" \
                                 "$(sync_addr_vendor "$a")" "$(sync_addr_relpath "$a")" 2>/dev/null)
              sync_conflict_record "$a" "$spp_lp" '' "$spp_peer" deleted >/dev/null
            fi
            printf 'conflict\t%s\n' "$a"
          else printf 'failed\t%s\n' "$a"; fi
          sync_res_unlock "$a"
        else
          printf 'addr=%s\n' "$a" > "$spp_t/req"
          if fleet_call "$spp_peer" sync-get "$spp_t/req" > "$spp_t/body" 2>/dev/null &&
             [ "$(sync_digest_file "$spp_t/body")" = "$r" ]; then
            # The fetch is the widest window in the pass: a whole round trip
            # stands between the digest that decided `pull` and this write. A
            # local edit that landed inside it is a real divergence, not a
            # stale read, so it is pinned rather than overwritten.
            if ! sync_pull_still_current "$a" "$l"; then
              sync_pull_raced "$a" "$b" "$r" "$spp_peer" "$spp_t/body" present
              sync_res_unlock "$a"; continue
            fi
            if sync_write "$a" "$spp_t/body"; then
              sync_base_set "$spp_peer" "$a" "$r"; printf 'pulled\t%s\n' "$a"
              sync_addr_is_tools "$a" && spp_tools=1
            else printf 'failed\t%s\n' "$a"; fi
            fleet_event sync-apply "addr=$(sync_addr_class "$a")|$(sync_addr_profile "$a")|$(sync_addr_vendor "$a") peer=$spp_peer"
          else printf 'failed\t%s\n' "$a"; fi
          sync_res_unlock "$a"
        fi ;;
      push)
        pw=$(sync_push_one "$spp_peer" "$a" "$l") || { printf 'failed\t%s\n' "$a"; continue; }
        case $pw in
          pull) sync_base_set "$spp_peer" "$a" "$l"; printf 'pushed\t%s\n' "$a" ;;
          # The receiver has the resource pinned behind an unresolved conflict
          # of its own. Nothing landed, so the base stays where it was.
          pinned) printf 'pinned\t%s\n' "$a" ;;
          conflict)
            # The receiver pinned it; pin the same thing here with real
            # candidates. Recording empty ones would make a later --local
            # choice "restore nothing", i.e. delete the edit it preserves.
            if ! sync_conflict_pinned "$a"; then
              # A zero-byte file is a perfectly good candidate: emptiness was
              # being read as "nothing came back", which is how a valid empty
              # remote turned into a tombstone. The digest decides, not -s.
              rs=$(sync_fetch_candidate "$spp_peer" "$a" "$r" "$spp_t/rbody")
              cf=; [ "$rs" = present ] && cf=$spp_t/rbody
              lp=$(sync_path "$(sync_addr_class "$a")" "$(sync_addr_profile "$a")" \
                             "$(sync_addr_vendor "$a")" "$(sync_addr_relpath "$a")" 2>/dev/null)
              sync_conflict_record "$a" "$lp" "$cf" "$spp_peer" "$rs" >/dev/null
            fi
            printf 'conflict\t%s\n' "$a" ;;
          *) printf 'push-%s\t%s\n' "${pw:-failed}" "$a" ;;
        esac ;;
      conflict)
        # Fetch the peer's bytes so the operator can see both candidates. A
        # fetch failure must still pin: not knowing is not agreement.
        rs=$(sync_fetch_candidate "$spp_peer" "$a" "$r" "$spp_t/body")
        cf=; [ "$rs" = present ] && cf=$spp_t/body
        lp=$(sync_path "$(sync_addr_class "$a")" "$(sync_addr_profile "$a")" \
                       "$(sync_addr_vendor "$a")" "$(sync_addr_relpath "$a")" 2>/dev/null)
        sync_conflict_record "$a" "$lp" "$cf" "$spp_peer" "$rs" >/dev/null
        printf 'conflict\t%s\n' "$a" ;;
    esac
  done < "$spp_t/addrs"
  rm -rf "$spp_t"
  # A manifest that arrived from a peer is the operator's designation, so the
  # tools it names are applied here without a second command. The authorization
  # is still the manifest and nothing else, and sync_tools_apply keeps the
  # active-task deferral rule, so this cannot interrupt running work.
  [ -n "$spp_tools" ] && [ -z "$spp_dry" ] &&
    sync_tools_apply | sed "s|^|tools\t|"
  return 0
}

# Every approved peer. An offline peer is reported and skipped: a sync pass is
# not allowed to fail the whole fleet because one machine is asleep.
sync_pass_all() {  # sync_pass_all [dryrun]
  fleet_peer_ids | while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$(fleet_self_id)" ] && continue
    fleet_approved "$pid" || continue
    sync_pass_peer "$pid" "${1:-}" | sed "s|^|$pid\t|"
  done
  return 0
}

# --- the automatic trigger -------------------------------------------------
#
# Replication is not something the operator has to remember. `sync_tick` is the
# single automatic entry point: it runs a pass for every approved peer that is
# either newly reachable (the reconnect trigger) or overdue (the ongoing one),
# and it retries deferred managed-tool work. It is deliberately one shot so it
# can be driven by a timer, by the tray, or by a test, and so that a hung peer
# cannot wedge a long-lived loop.

sync_seen_dir() { echo "$(sync_root)/seen"; }
SYNC_INTERVAL_DEFAULT=${N2_FLEET_SYNC_INTERVAL:-300}

sync_seen_get() {  # sync_seen_get <peer> <field>  -> value or empty
  ssg_f="$(sync_seen_dir)/$(fleet_slug "$1")"
  [ -f "$ssg_f" ] || return 0
  awk -F'=' -v k="$2" '$1==k{sub(/^[^=]*=/,"");print}' "$ssg_f" | tail -1
}

sync_seen_set() {  # sync_seen_set <peer> <field> <value>
  mkdir -p "$(sync_seen_dir)" 2>/dev/null
  sss_f="$(sync_seen_dir)/$(fleet_slug "$1")"
  sss_t="$sss_f.$$"
  { [ -f "$sss_f" ] && grep -v "^$2=" "$sss_f"; printf '%s=%s\n' "$2" "$3"; } > "$sss_t" 2>/dev/null
  mv "$sss_t" "$sss_f" 2>/dev/null || rm -f "$sss_t"
}

sync_epoch() { date +%s 2>/dev/null || echo 0; }

# One automatic round. Prints one line per peer saying what it decided and why,
# because an automatic trigger that is invisible is indistinguishable from one
# that is broken.
sync_tick() {  # sync_tick [interval-seconds]
  sync_need
  sti=${1:-$SYNC_INTERVAL_DEFAULT}
  case $sti in ''|*[!0-9]*) sti=$SYNC_INTERVAL_DEFAULT ;; esac
  stnow=$(sync_epoch)
  # Task disconnection is independent of profile-sync freshness. Reconcile
  # every tick, without retrying work or moving its outputs.
  if command -v exec_reconcile >/dev/null 2>&1; then
    sync_usage_pull
    exec_discover_tasks
    exec_reconcile | sed 's/^/task\t/'
  fi
  for stpid in $(fleet_peer_ids); do
    [ -n "$stpid" ] || continue
    [ "$stpid" = "$(fleet_self_id)" ] && continue
    fleet_approved "$stpid" || continue
    stwas=$(sync_seen_get "$stpid" state)
    if ! fleet_call "$stpid" ping >/dev/null 2>&1; then
      # Unreachable is a fact to record, not a reason to drop the agreed base:
      # the next tick after it returns is the reconnect trigger.
      [ "$stwas" = offline ] || fleet_event sync-peer-offline "peer=$stpid"
      sync_seen_set "$stpid" state offline
      printf 'offline\t%s\n' "$stpid"; continue
    fi
    stlast=$(sync_seen_get "$stpid" last_pass); case $stlast in ''|*[!0-9]*) stlast=0 ;; esac
    stwhy=
    if [ "$stwas" != online ]; then stwhy=reconnect
    elif [ $((stnow - stlast)) -ge "$sti" ]; then stwhy=interval
    fi
    sync_seen_set "$stpid" state online
    if [ -z "$stwhy" ]; then printf 'fresh\t%s\n' "$stpid"; continue; fi
    fleet_event sync-tick "peer=$stpid trigger=$stwhy"
    printf 'pass\t%s\t%s\n' "$stpid" "$stwhy"
    sync_pass_peer "$stpid" | sed "s|^|$stpid\t|"
    sync_seen_set "$stpid" last_pass "$(sync_epoch)"
  done
  # Every managed tool is reconciled on every tick, not just the ones an active
  # task held back. Gating this on a non-empty deferred list meant designating a
  # tool never installed it on its own, and a tool that was installed and then
  # removed or downgraded stayed broken until someone ran `tools apply` by hand.
  # Ongoing repair is the whole point of an automatic trigger; the deferred list
  # is reported when it is non-empty because a retry is worth naming.
  # Deferral still applies inside sync_tools_apply, so this cannot interrupt a
  # running task with a disruptive install.
  sync_tools_apply | sed "s|^|tools\t|"
  # Counted *after* the pass, not before it. Reading the file first reported
  # the previous tick's list: a tool whose blocking task had finished, or whose
  # grant had been withdrawn, was still announced as a pending retry on the very
  # tick that resolved it, so `tools-retry` and `tools deferred` disagreed.
  if [ -s "$(sync_tools_deferred)" ]; then
    printf 'tools-retry\t%s\n' "$(sync_num "$(grep -c . "$(sync_tools_deferred)" 2>/dev/null)")"
  fi
  return 0
}

# --- the installed timer ---------------------------------------------------
#
# `sync tick` is only automatic if something actually calls it. On macOS that
# is a launchd user agent: it survives logout and reboot and it runs whether or
# not the tray app is open, which matters because the CLI is the behaviour
# authority and the tray is one of its clients. A foreground `sync auto` loop
# dies with its terminal, so it is a debugging tool, not the mechanism.
#
# The plist directory and the launchctl binary are overridable so the suite can
# install against a fixture instead of the operator's real login session. They
# are a test seam, not a fallback: with neither set this installs for real.

sync_service_label()  { echo "${N2_FLEET_SYNC_LABEL:-com.n2agents.fleet-sync}"; }
sync_service_dir()    { echo "${N2_FLEET_LAUNCH_DIR:-$HOME/Library/LaunchAgents}"; }
sync_service_plist()  { echo "$(sync_service_dir)/$(sync_service_label).plist"; }
sync_service_log()    { echo "$(sync_root)/service.log"; }
sync_launchctl()      { echo "${N2_FLEET_LAUNCHCTL:-launchctl}"; }
sync_service_domain() { echo "gui/$(id -u)"; }

sync_xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# The plist records absolute paths and the PATH in force at install time.
# launchd hands a job a near-empty environment, and this job shells out to ssh
# and ssh-keygen; inheriting the installing shell's PATH is what makes the
# installed timer behave like the command the operator just ran.
sync_service_write() {  # sync_service_write <interval>
  ssw_i=$1
  ssw_self=${self:-}
  [ -n "$ssw_self" ] && [ -f "$ssw_self" ] || { echo "agents: cannot locate the agents entry point" >&2; return 1; }
  mkdir -p "$(sync_service_dir)" "$(sync_root)" 2>/dev/null || true
  ssw_p="$(sync_service_plist)"; ssw_t="$ssw_p.$$"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    printf '  <key>Label</key><string>%s</string>\n' "$(sync_xml "$(sync_service_label)")"
    echo '  <key>ProgramArguments</key>'
    echo '  <array>'
    printf '    <string>/bin/sh</string>\n'
    printf '    <string>%s</string>\n' "$(sync_xml "$ssw_self")"
    printf '    <string>fleet</string><string>sync</string><string>tick</string>\n'
    printf '    <string>--interval</string><string>%s</string>\n' "$ssw_i"
    echo '  </array>'
    echo '  <key>EnvironmentVariables</key>'
    echo '  <dict>'
    printf '    <key>HOME</key><string>%s</string>\n' "$(sync_xml "$HOME")"
    printf '    <key>PATH</key><string>%s</string>\n' "$(sync_xml "$PATH")"
    echo '  </dict>'
    printf '  <key>StartInterval</key><integer>%s</integer>\n' "$ssw_i"
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>ProcessType</key><string>Background</string>'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(sync_xml "$(sync_service_log)")"
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(sync_xml "$(sync_service_log)")"
    echo '</dict>'
    echo '</plist>'
  } > "$ssw_t" || { rm -f "$ssw_t"; return 1; }
  mv "$ssw_t" "$ssw_p" || { rm -f "$ssw_t"; return 1; }
  return 0
}

sync_service_loaded() {
  "$(sync_launchctl)" print "$(sync_service_domain)/$(sync_service_label)" >/dev/null 2>&1
}

sync_service_install() {  # sync_service_install <interval>
  sync_need
  ssi_i=${1:-$SYNC_INTERVAL_DEFAULT}
  case $ssi_i in ''|*[!0-9]*) fleet_die "--interval takes seconds" ;; esac
  [ "$ssi_i" -ge 30 ] || fleet_die "--interval below 30s would spend more time starting than syncing"
  sync_service_write "$ssi_i" || fleet_die "could not write $(sync_service_plist)"
  printf 'plist\t%s\n' "$(sync_service_plist)"
  # Replacing an already-loaded job is normal, so an unload failure is not an
  # error; a bootstrap failure is, and it is reported rather than swallowed.
  "$(sync_launchctl)" bootout "$(sync_service_domain)/$(sync_service_label)" >/dev/null 2>&1 || true
  if "$(sync_launchctl)" bootstrap "$(sync_service_domain)" "$(sync_service_plist)" >/dev/null 2>&1; then
    fleet_event sync-service-install "interval=$ssi_i"
    printf 'loaded\t%s\tinterval=%s\n' "$(sync_service_label)" "$ssi_i"
    return 0
  fi
  printf 'load-failed\t%s\n' "$(sync_service_label)"
  echo "agents: wrote the plist but launchd refused to load it" >&2
  return 1
}

sync_service_uninstall() {
  ssu_p="$(sync_service_plist)"
  ssu_was=no; [ -f "$ssu_p" ] && ssu_was=yes
  "$(sync_launchctl)" bootout "$(sync_service_domain)/$(sync_service_label)" >/dev/null 2>&1 || true
  rm -f "$ssu_p"
  fleet_event sync-service-uninstall "present=$ssu_was"
  printf 'removed\t%s\t%s\n' "$(sync_service_label)" "$ssu_was"
  return 0
}

sync_service_status() {
  ssts_p="$(sync_service_plist)"
  if [ -f "$ssts_p" ]; then
    printf 'plist\t%s\n' "$ssts_p"
    printf 'interval\t%s\n' "$(sed -n 's|.*<key>StartInterval</key><integer>\([0-9]*\)</integer>.*|\1|p' "$ssts_p" 2>/dev/null | tail -1)"
  else
    printf 'plist\tnone\n'
  fi
  if sync_service_loaded; then printf 'loaded\tyes\n'; else printf 'loaded\tno\n'; fi
  printf 'log\t%s\n' "$(sync_service_log)"
  # Last automatic round, read from the journal the tick itself writes.
  ssts_l=$(grep -h 'sync-tick\|sync-service' "$fleet_root/events.log" 2>/dev/null | tail -1 | cut -f1)
  printf 'last-event\t%s\n' "${ssts_l:-never}"
  return 0
}

# --- explicit conflict resolution ------------------------------------------

# The operator picks a side. Code never does. Resolving records the chosen
# bytes as the new agreed base, so the next pass propagates the choice instead
# of re-detecting the same conflict.
sync_resolve() {  # sync_resolve <id> local|remote
  sync_conflict_id_ok "${1:-}" || {
    echo "agents: not a conflict id: ${1:-}" >&2
    echo "agents: an id is the 12-character value in 'agents fleet sync conflicts'" >&2
    return 1
  }
  sr_d="$(sync_conflict_dir)/$1"
  [ -d "$sr_d" ] || { echo "agents: no such conflict: $1" >&2; return 1; }
  sr_a=$(fleet_meta_get_file "$sr_d/meta" addr)
  [ -n "$sr_a" ] || { echo "agents: conflict $1 has no address" >&2; return 1; }
  sr_p=$(fleet_meta_get_file "$sr_d/meta" peer)
  sr_r=$(fleet_meta_get_file "$sr_d/meta" remote)
  sr_note=
  # A resolution reads the live bytes and then writes; a push arriving for the
  # same address in between would decide against bytes the write is about to
  # replace. Same lock, same ordering as everywhere else.
  sync_res_lock "$sr_a" || return 1
  # Clear the pin *first*, as an atomic rename. If it cannot be cleared this
  # resolution must not happen at all: the old code wrote the peer's bytes,
  # advanced the base, emitted sync-resolved and printed "resolved", then ran
  # an `rm -rf` whose failure it never looked at -- leaving the resource
  # changed and the pin still standing, so every later pass refused to sync the
  # very address the operator had just settled. Staging up front means a
  # refusal costs nothing: the pin is intact and still resolvable.
  sr_stage=$(sync_conflict_stage "$sr_d") || {
    echo "agents: could not clear the conflict record at $sr_d - $1 is not resolved" >&2
    printf 'unresolved\t%s\t%s\n' "$1" "$sr_a"
    sync_res_unlock "$sr_a"; return 1
  }
  case $2 in
    local)
      # "local" means *this machine's version*, which is whatever the file holds
      # now — not the snapshot taken when the conflict was pinned. A pinned
      # conflict is never written to by sync (see sync_absorb), so the only way
      # the live file can have moved on is a deliberate local edit made while
      # the conflict sat unresolved. Restoring the snapshot over it would throw
      # that edit away silently, which is exactly the "code picks a winner"
      # behaviour this whole file exists to avoid. So: touch nothing, and say
      # so when the live bytes are not the ones recorded.
      sr_live=$(sync_local_digest "$sr_a" 2>/dev/null)
      sr_snap=$(fleet_meta_get_file "$sr_stage/meta" local)
      [ -n "$sr_live" ] || sr_live=$SYNC_TOMBSTONE
      [ -n "$sr_snap" ] || sr_snap=$SYNC_TOMBSTONE
      [ "$sr_live" = "$sr_snap" ] || sr_note=live ;;
    remote)
      # An address that has left this machine's scope since the pin was made
      # (an exception was added, or an auth opt-in was withdrawn) must not be
      # overwritten with the peer's bytes: the exception *is* the operator's
      # statement that this machine keeps its own copy. Refuse loudly, keep the
      # pin, and point at the escape hatch -- `--local` writes nothing, so it
      # clears the pin without contradicting the exception.
      if ! sync_scope_ok "$sr_a"; then
        echo "agents: $sr_a is no longer in this machine's sync scope (an exception or auth opt-out covers it); taking the peer's version would override that decision" >&2
        echo "agents: resolve it with --local to keep this machine's copy, or remove the exception first" >&2
        printf 'out-of-scope\t%s\t%s\n' "$1" "$sr_a"
        sync_conflict_unstage "$sr_stage" "$sr_d"
        sync_res_unlock "$sr_a"; return 1
      fi
      if [ -f "$sr_stage/remote" ]; then sync_write "$sr_a" "$sr_stage/remote" || { sync_conflict_unstage "$sr_stage" "$sr_d"; sync_res_unlock "$sr_a"; return 1; }
      elif [ -f "$sr_stage/remote.deleted" ]; then
        # `--remote` on a blocked profile deletion is the operator saying yes to
        # exactly the removal the conflict listing described, so this is the one
        # call site that forces it past the blockers.
        sync_write "$sr_a" '' '' "$sr_p" force || { sync_conflict_unstage "$sr_stage" "$sr_d"; sync_res_unlock "$sr_a"; return 1; }
      else
        # The peer's candidate was never obtained (fetch failed, or its bytes
        # did not hash to what it advertised). Choosing it would mean writing
        # bytes nobody has, and the old code expressed that as a deletion.
        # The pin stays; the next pass retries the fetch.
        echo "agents: the peer's version of this conflict is not available yet; the pin stays until it can be fetched" >&2
        printf 'unavailable\t%s\t%s\n' "$1" "$(fleet_meta_get_file "$sr_stage/meta" peer)"
        sync_conflict_unstage "$sr_stage" "$sr_d"
        sync_res_unlock "$sr_a"; return 1
      fi ;;
    *) echo "agents: choose --local or --remote" >&2
       sync_conflict_unstage "$sr_stage" "$sr_d"
       sync_res_unlock "$sr_a"; return 1 ;;
  esac
  # The base becomes what the peer had when the conflict was detected. Choosing
  # "remote" therefore reads as converged next pass; choosing "local" reads as
  # a push, so the operator's choice travels instead of re-conflicting.
  [ -n "$sr_p" ] && [ -n "$sr_r" ] && sync_base_set "$sr_p" "$sr_a" "$sr_r"
  sync_res_unlock "$sr_a"
  rm -rf "$sr_stage"
  fleet_event sync-resolved "id=$1 choice=$2 addr=$(sync_addr_class "$sr_a")|$(sync_addr_profile "$sr_a")|$(sync_addr_vendor "$sr_a")"
  if [ -n "$sr_note" ]; then
    printf 'resolved\t%s\t%s\t%s\n' "$1" "$2" "$sr_note"
    echo "agents: kept the current local contents, which changed after the conflict was recorded" >&2
  else
    printf 'resolved\t%s\t%s\n' "$1" "$2"
  fi
}

# --- managed utilities -----------------------------------------------------
#
# Authorization is the manifest and nothing else. There is no path in this file
# that installs, updates or removes a utility the operator has not written into
# it, and `tools install` refuses an unlisted name rather than adding it.

sync_tools_deferred() { echo "$fleet_root/tools/deferred"; }
sync_tasks_dir() { echo "${N2_FLEET_TASKS:-$fleet_root/tasks/active}"; }

# A task is active if the execution task has a live record for it. Kept here so
# the deferral rule reads from real task state rather than a guess.
# A record may name the process that owns it as a `pid <n>` line. A record
# whose owner is provably gone is stale, and a stale record is not active work:
# left counted, a worker killed mid-task would pin every `--disruptive` update
# in `tools/deferred` forever while the operator kept reading "deferred,
# retried on the next apply" for a retry that could never succeed. That is the
# same silent-forever shape as an interrupted conflict resolution.
#
# The asymmetry is deliberate. A record that declares no pid, or declares one
# we cannot parse, is counted as ACTIVE: liveness we cannot prove is never
# treated as permission to interrupt somebody's work. Only a record that says
# who owns it, and whose owner is gone, is reaped.
#
# Honest limit: liveness is `ps -p`, the same check the conflict sweep uses, so
# a recycled pid reads as alive and the record is kept one more pass. That errs
# toward deferring an update, never toward running one against live work.
# Reaped records are renamed in place with a `.stale-` prefix rather than
# deleted — `ls -1` does not list them so they leave the count, but the bytes
# the execution task wrote survive for reconciliation.
sync_tasks_reap() {
  str_d=$(sync_tasks_dir); [ -d "$str_d" ] || return 0
  for str_f in "$str_d"/*; do
    [ -f "$str_f" ] || continue
    str_n=${str_f##*/}
    case $str_n in .*|*/*) continue ;; esac
    str_p=$(sed -n 's/^pid[ =]*\([0-9][0-9]*\)$/\1/p' "$str_f" 2>/dev/null | head -1)
    [ -n "$str_p" ] || continue          # no owner declared -> stays active
    ps -p "$str_p" >/dev/null 2>&1 && continue
    mv "$str_f" "$str_d/.stale-$str_n" 2>/dev/null || continue
    fleet_event task-record-stale "task=$str_n pid=$str_p" 2>/dev/null || true
  done
  return 0
}

sync_tasks_active() {
  sync_tasks_reap
  std=$(sync_tasks_dir); [ -d "$std" ] || { echo 0; return 0; }
  # grep -c exits 1 on zero matches; take the count, not a second echo.
  sta_n=$(ls -1 "$std" 2>/dev/null | grep -c . 2>/dev/null)
  case ${sta_n:-0} in ''|*[!0-9]*) echo 0 ;; *) echo "$sta_n" ;; esac
}

# A manifest line is one record of five fields, so no field may contain the
# delimiter. An installer *is* a shell command and may legitimately contain a
# pipeline; written raw it shifted every later field, which moved the
# `disruptive` flag out of field 5 — a disruptive installer then ran during
# active work instead of being deferred. Values are escaped on the way in and
# restored on the way out, and a line that is not exactly five well-formed
# fields is refused rather than parsed into whatever it happens to look like.
sync_tool_enc() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/|/%7C/g' |
    awk 'NR>1{printf "%%0A"} {printf "%s", $0}'
}

sync_tool_dec() {
  printf '%s' "$1" |
    awk '{gsub(/%7C/,"|"); gsub(/%0A/,"\n"); gsub(/%25/,"%"); printf "%s", $0}'
}

sync_tool_line_ok() {  # sync_tool_line_ok <line>
  [ "$(printf '%s' "$1" | awk -F'|' '{print NF}')" = 5 ] || return 1
  case $(printf '%s' "$1" | cut -d'|' -f5) in ''|disruptive) ;; *) return 1 ;; esac
  case $(printf '%s' "$1" | cut -d'|' -f1) in ''|'#'*) return 1 ;; esac
  # Field 3 is the check command, and it is the only way this machine can tell
  # `install` from `ok`. Without it `sync_tool_state` answers `install` forever:
  # the installer re-runs on every tick and a successful install is still
  # reported `failed`, because the post-install re-check can never reach `ok`.
  # A record that cannot be verified is refused rather than run on a loop.
  case $(printf '%s' "$1" | cut -d'|' -f3) in '') return 1 ;; esac
  return 0
}

# --- operator approval of a runnable command -------------------------------
#
# The manifest is a *synced* resource, so a peer can rewrite this machine's
# install and check commands by editing its own copy. Authorization to run a
# command therefore cannot be "it is in the manifest": that would make any
# enrolled machine able to execute arbitrary shell here, which is a far larger
# grant than "keep my fleet-managed utilities current".
#
# So designation and execution are separated. The manifest still says WHICH
# utilities the fleet manages; this file says which exact commands THIS machine
# has agreed to run. A record arrives, replicates and is listed as normal, but
# an install or check command this operator has never approved does not run
# until `agents fleet tools approve <name>` says so. Approval is keyed on the
# commands, not on the version, so the agreed behavior is unchanged where it
# matters: a version bump that keeps the approved commands applies
# automatically, active-task deferral and all. Adding a tool here is itself the
# operator's word, so `tools add` approves what it stores.
sync_tools_approved_file() { echo "$fleet_root/tools/approved"; }

sync_tool_key() {  # sync_tool_key <line> -> digest of the commands it would run
  # The stored (escaped) fields, so the key covers exactly the bytes that
  # reach `sh -c`. Separated by a newline, which neither escaped field can
  # contain, so no pair of commands can collide with another pair.
  printf '%s\n%s\n' "$(sync_tool_field "$1" 4)" "$(sync_tool_field "$1" 3)" |
    shasum -a 256 2>/dev/null | awk '{print substr($1,1,32)}'
}

sync_tool_approved() {  # sync_tool_approved <name> <line>
  sta_f=$(sync_tools_approved_file); [ -f "$sta_f" ] || return 1
  # -F and -x: a tool name is operator text, never a regular expression.
  grep -qxF "$1|$(sync_tool_key "$2")" "$sta_f" 2>/dev/null
}

sync_tool_approve() {  # sync_tool_approve <name> <line>
  stp_f=$(sync_tools_approved_file); mkdir -p "$(dirname "$stp_f")" 2>/dev/null || return 1
  stp_k="$1|$(sync_tool_key "$2")"
  grep -qxF "$stp_k" "$stp_f" 2>/dev/null && return 0
  printf '%s\n' "$stp_k" >> "$stp_f" || return 1
  # Read it back: an approval that did not reach the file is not an approval,
  # and reporting one would leave the operator believing a pending install was
  # cleared while every later pass keeps holding it.
  grep -qxF "$stp_k" "$stp_f" 2>/dev/null
}

sync_tool_approval_forget() {  # sync_tool_approval_forget <name>
  stq_f=$(sync_tools_approved_file); [ -f "$stq_f" ] || return 0
  stq_t="$stq_f.$$"
  awk -F'|' -v n="$1" '$1!=n' "$stq_f" > "$stq_t" 2>/dev/null && mv "$stq_t" "$stq_f" ||
    { rm -f "$stq_t" 2>/dev/null; return 1; }
  return 0
}

sync_tool_line() {  # sync_tool_line <name> -> name|version|check|install|disruptive
  stf=$(sync_tools_manifest); [ -f "$stf" ] || return 1
  stl_out=$(awk -F'|' -v n="$1" 'NF==5 && $1==n' "$stf" | tail -1)
  [ -n "$stl_out" ] || return 1
  sync_tool_line_ok "$stl_out" || return 1
  printf '%s\n' "$stl_out"
}

sync_tool_managed() { sync_tool_line "$1" >/dev/null 2>&1; }

sync_tool_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# Fields 2-4 are stored escaped; these are the only readers that should exist.
sync_tool_value() { sync_tool_dec "$(sync_tool_field "$1" "$2")"; }

sync_tool_installed_version() {  # <checkcmd>
  [ -n "$1" ] || return 1
  sh -c "$1" 2>/dev/null | head -1 | tr -d '\r'
}

# Returns: ok | install | update | pending-approval | unmanaged
#
# The check command is itself a command from the manifest, so it is not run
# before approval either: reading a version is `sh -c` like any other line.
sync_tool_state() {  # sync_tool_state <name> [exact-record]
  # Approve and execute one snapshot even if replication replaces the manifest.
  if [ "$#" -ge 2 ]; then stl=$2
  else stl=$(sync_tool_line "$1") || { echo unmanaged; return 0; }; fi
  sync_tool_approved "$1" "$stl" || { echo pending-approval; return 0; }
  want=$(sync_tool_value "$stl" 2); chk=$(sync_tool_value "$stl" 3)
  have=$(sync_tool_installed_version "$chk")
  if [ -z "$have" ]; then echo install; return 0; fi
  [ -z "$want" ] && { echo ok; return 0; }
  [ "$have" = "$want" ] && { echo ok; return 0; }
  echo update
}

# Apply pending work. A disruptive tool is deferred while a task is running —
# recorded, reported and retried on the next apply — instead of being forced
# through or silently dropped. A non-disruptive one applies immediately, which
# is the agreed behavior: updates do not wait for the fleet to go idle.
# One apply at a time: a put-triggered apply and a tick would otherwise run the
# same installer twice and truncate each other's deferred list.
sync_tools_apply() {  # sync_tools_apply [--force-idle-check]
  sync_need
  sync_res_lock "tools-apply" || { printf 'busy\tapply already running\n'; return 0; }
  sync_tools_apply_locked "$@"; sta_rc=$?
  sync_res_unlock "tools-apply"
  return $sta_rc
}

sync_tools_apply_locked() {
  stf=$(sync_tools_manifest); [ -f "$stf" ] || return 0
  busy=$(sync_tasks_active)
  : > "$(sync_tools_deferred)"
  # `apply` is the batch entry point, and a batch that could not do what it was
  # asked must say so in its exit status. Reporting 0 while an installer failed
  # is the same false success as `tools rm <typo>`: the tray and any operator
  # script that runs `tools apply || alert` never learn the fleet is drifting.
  # A deferral is NOT a failure — holding a disruptive update back while a task
  # runs is the agreed behavior succeeding, and it is retried on the next tick.
  sta_fail=0
  while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    if ! sync_tool_line_ok "$line"; then
      # A malformed record is not authorization. Refuse it loudly instead of
      # guessing which field was meant to be the disruptive flag.
      printf 'invalid\t%s\n' "$(printf '%s' "$line" | cut -d'|' -f1)"
      fleet_event tool-invalid "tool=$(printf '%s' "$line" | cut -d'|' -f1)"
      sta_fail=1; continue
    fi
    name=$(sync_tool_field "$line" 1)
    inst=$(sync_tool_value "$line" 4)
    disruptive=$(sync_tool_field "$line" 5)
    st=$(sync_tool_state "$name" "$line")
    case $st in
      ok) printf 'ok\t%s\n' "$name"; continue ;;
      unmanaged) continue ;;
      pending-approval)
        # Not a failure and not a deferral: the record is fine, this machine
        # has simply never agreed to run these commands. It is reported on
        # every pass so the operator can see what is waiting, and it stays
        # waiting until `tools approve` says otherwise.
        fleet_event tool-pending-approval "tool=$name"
        printf 'pending-approval\t%s\n' "$name"; continue ;;
    esac
    if [ "$disruptive" = "disruptive" ] && [ "$busy" -gt 0 ]; then
      printf '%s\t%s\n' "$name" "$st" >> "$(sync_tools_deferred)"
      fleet_event tool-deferred "tool=$name want=$st active_tasks=$busy"
      printf 'deferred\t%s\t%s\tactive_tasks=%s\n' "$name" "$st" "$busy"; continue
    fi
    [ -n "$inst" ] || { printf 'no-installer\t%s\n' "$name"; continue; }
    if sh -c "$inst" >/dev/null 2>&1; then
      now=$(sync_tool_state "$name" "$line")
      if [ "$now" = ok ]; then
        fleet_event tool-applied "tool=$name action=$st"
        printf '%s\t%s\n' "$st" "$name"
      else
        # An installer that exits 0 without producing the requested version is
        # a failure, not a success: reporting otherwise is how a fleet drifts.
        fleet_event tool-failed "tool=$name action=$st reason=version-not-reached"
        printf 'failed\t%s\t%s\n' "$name" "$st"; sta_fail=1
      fi
    else
      fleet_event tool-failed "tool=$name action=$st reason=installer-exit"
      printf 'failed\t%s\t%s\n' "$name" "$st"; sta_fail=1
    fi
  done < "$stf"
  [ "$sta_fail" = 0 ] || return 1
  return 0
}

# --- CLI -------------------------------------------------------------------

sync_usage() {
  cat <<'EOF'
agents fleet sync <verb>

  categories [settings|skills|mcp|auth on|off]  choose what this machine shares

  now [--peer <peerid>] [--dry-run]   one replication pass (all approved peers)
  tick [--interval <sec>]             automatic round: reconnected + overdue peers
  auto [--interval <sec>] [--rounds <n>]  repeat tick on a timer (default: forever)
  service install [--interval <sec>]  install the launchd timer that runs tick
  service uninstall | service status   remove it / show plist, load state, last run
  status [--porcelain]                scope, exceptions, conflicts, last pass
  scope                               what this machine would advertise
  conflicts                           unresolved conflicts awaiting a choice
                                      (scope:out = an exception now covers it,
                                       so only --local can resolve it)
  show <id>                           one conflict: address, peer, both digests
  resolve <id> --local|--remote       record the operator's choice
  except add <class> <profile> <vendor> [glob]   keep this machine different
  except list | except rm <n>
  auth list                           provider portability matrix + opt-in state
  auth enable <vendor> | auth disable <vendor>
EOF
}

cmd_fleet_sync() {
  set +e
  sv=${1:-status}; [ $# -ge 1 ] && shift
  case $sv in
    categories) sync_categories "$@" ;;
    import-local)
      [ "${N2_FLEET_QA:-}" = 1 ] || fleet_die "import-local is only available in the fleet QA build"
      /usr/bin/python3 "$scripts_dir/fleet-qa-import.py" "$@" ;;
    now)
      sync_need; sp=; dry=
      while [ $# -gt 0 ]; do case $1 in
        --peer) sync_needval "$1" "$#" "${2:-}"; sp=$2; shift 2 ;;
        --dry-run) dry=dry; shift ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      if [ -n "$sp" ]; then
        fleet_approved "$sp" || fleet_die "peer is not approved: $sp"
        sync_pass_peer "$sp" "$dry" | sed "s|^|$sp\t|"
      else
        sync_pass_all "$dry"
      fi
      # A conflict is not an error, but it must not be quiet either.
      sc=$(sync_conflict_count)
      [ "${sc:-0}" -gt 0 ] &&
        echo "agents: $sc unresolved conflict(s) — see 'agents fleet sync conflicts'" >&2
      return 0 ;;
    tick)
      ti=$SYNC_INTERVAL_DEFAULT
      while [ $# -gt 0 ]; do case $1 in
        --interval) sync_needval "$1" "$#" "${2:-}"; ti=$2; shift 2 ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      # `auto` and `service install` both reject a non-numeric interval. This
      # one used to accept it and fall back to the default inside sync_tick,
      # so `tick --interval 300s` exited 0 having silently ignored the cadence
      # the operator asked for. A wrapper or timer that calls tick reads that
      # exit code as "the requested cadence is in force".
      sync_seconds_ok --interval "$ti"
      sync_tick "$ti"; return 0 ;;
    service)
      ssv=${1:-status}; [ $# -ge 1 ] && shift
      svi=$SYNC_INTERVAL_DEFAULT
      while [ $# -gt 0 ]; do case $1 in
        --interval) sync_needval "$1" "$#" "${2:-}"; svi=$2; shift 2 ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      case $ssv in
        install)   sync_service_install "$svi"; return $? ;;
        uninstall) sync_service_uninstall; return $? ;;
        status)    sync_service_status; return $? ;;
        *) fleet_die "unknown service verb: $ssv" ;;
      esac ;;
    auto)
      ai=$SYNC_INTERVAL_DEFAULT; ar=0
      while [ $# -gt 0 ]; do case $1 in
        --interval) sync_needval "$1" "$#" "${2:-}"; ai=$2; shift 2 ;;
        --rounds) sync_needval "$1" "$#" "${2:-}"; ar=$2; shift 2 ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      sync_seconds_ok --interval "$ai"
      case $ar in ''|*[!0-9]*) fleet_die "--rounds takes a count" ;; esac
      an=0
      while :; do
        an=$((an+1))
        printf 'round\t%s\n' "$an"
        sync_tick "$ai"
        [ "$ar" -gt 0 ] && [ "$an" -ge "$ar" ] && break
        sleep "$ai"
      done
      return 0 ;;
    scope)
      sync_need
      sync_manifest | while IFS="$(printf '\t')" read -r a d; do
        [ -n "$a" ] || continue
        sync_scope_ok "$a" && printf '%s\t%s\n' "$a" "$d"
      done ;;
    status)
      sync_need
      printf 'self\t%s\t%s\n' "$(fleet_self_machine)" "$(fleet_self_id)"
      printf 'resources\t%s\n' "$(sync_num "$(cmd_fleet_sync scope | grep -c . 2>/dev/null)")"
      printf 'agreed\t%s\n' "$(sync_num "$(grep -c . "$(sync_state_file)" 2>/dev/null)")"
      printf 'exceptions\t%s\n' "$(sync_num "$(grep -cv '^#\|^$' "$(sync_exceptions_file)" 2>/dev/null)")"
      printf 'conflicts\t%s\n' "$(sync_conflict_count)"
      for v in $N2_VENDORS; do
        sync_auth_optin "$v" && o=opted-in || o=off
        printf 'auth\t%s\t%s\t%s\n' "$v" "$(sync_auth_support "$v")" "$o"
      done ;;
    conflicts) sync_need; sync_conflicts ;;
    show)
      sync_need; [ -n "${1:-}" ] || fleet_die "usage: agents fleet sync show <id>"
      sync_conflict_id_ok "$1" || fleet_die "not a conflict id: $1 (an id is the 12-character value in 'agents fleet sync conflicts')"
      d="$(sync_conflict_dir)/$1"; [ -d "$d" ] || fleet_die "no such conflict: $1"
      # Digests and presence, never the bytes: a conflicting credential must
      # stay unprintable even when the operator is inspecting the conflict.
      cat "$d/meta"
      [ -f "$d/local" ]  && printf 'local_bytes=%s\n' "$(wc -c < "$d/local" | tr -d ' ')"  || printf 'local=deleted\n'
      [ -f "$d/remote" ] && printf 'remote_bytes=%s\n' "$(wc -c < "$d/remote" | tr -d ' ')" || printf 'remote=deleted\n'
      # Other machines that diverged on the same resource while this pin waited.
      # Their bytes are not candidates here; the operator is told they exist so
      # resolving this pin is not mistaken for agreeing with the whole fleet.
      if [ -f "$d/others" ]; then
        while IFS='	' read -r op od os; do
          [ -n "$op" ] || continue
          printf 'also_diverged=%s\t%s\t%s\n' "$op" "$od" "$os"
        done < "$d/others"
      fi
      return 0 ;;
    resolve)
      sync_need; [ -n "${1:-}" ] || fleet_die "usage: agents fleet sync resolve <id> --local|--remote"
      rid=$1; shift; choice=
      while [ $# -gt 0 ]; do case $1 in
        --local) choice=local; shift ;; --remote) choice=remote; shift ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      [ -n "$choice" ] || fleet_die "resolve requires --local or --remote"
      sync_resolve "$rid" "$choice" || return 1 ;;
    except)
      sync_need; ev=${1:-list}; [ $# -ge 1 ] && shift
      f=$(sync_exceptions_file)
      case $ev in
        add)
          [ $# -ge 3 ] || fleet_die "usage: agents fleet sync except add <class> <profile> <vendor> [glob]"
          sync_valid_class "$1" || [ "$1" = '*' ] || fleet_die "unknown class: $1"
          # The class was already checked; the other three were not, so a typo
          # in the vendor or profile stored a record that could never match and
          # still reported `excepted`. See sync_except_name_ok.
          sync_except_name_ok "$2" ||
            fleet_die "not a profile name: '$2' (a profile name has no '/', '|', tab or newline, and is not '.' or '..')"
          [ "$3" = '*' ] || [ "$3" = '-' ] || vendor_known "$3" ||
            fleet_die "unknown vendor: '$3' (known: $N2_VENDORS; '-' is the fleet tools slot, '*' is every vendor)"
          sync_except_name_ok "$3" ||
            fleet_die "not a vendor name: '$3'"
          sync_except_glob_ok "${4:-*}" ||
            fleet_die "not a path glob: '${4:-*}' (a glob may not be empty or contain a tab or newline)"
          printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-*}" >> "$f"
          fleet_event sync-exception "add=$1|$2|$3"
          printf 'excepted\t%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-*}" ;;
        # `list`, `rm` and the `exceptions` counter in `status` must agree on
        # one definition of an exception line, or a number the operator reads
        # here means a different line to `rm`. The definition is the matcher's:
        # blank lines and `#` comments are not exceptions. Numbering is dense
        # over those lines, so index N is always the Nth listed exception no
        # matter what blanks or comments a hand-edit left in the file.
        list) awk '!/^#/ && !/^$/ { printf "%d:%s\n", ++i, $0 }' "$f" 2>/dev/null || true ;;
        rm)
          # Removing an exception puts a resource back in sync scope, so a
          # removal that quietly matched nothing is the dangerous direction:
          # the operator reads "removed" and believes the machine now takes
          # the fleet's copy while the exception is still standing. Refuse
          # anything that is not an existing line number.
          [ -n "${1:-}" ] || fleet_die "usage: agents fleet sync except rm <n>"
          case $1 in ''|*[!0-9]*)
            fleet_die "except rm takes a line number from 'agents fleet sync except list', not '$1'" ;;
          esac
          n_ex=$(sync_num "$(grep -cv '^#\|^$' "$f" 2>/dev/null)")
          [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le "$n_ex" ] ||
            fleet_die "there is no exception numbered $1 ($n_ex on this machine); run 'agents fleet sync except list'"
          # Count the same lines `list` numbers, and drop the Nth of those.
          # Deleting raw line N instead silently removed a blank line and
          # reported success while every real exception stayed in force.
          t="$f.$$"
          awk -v n="$1" '/^#/ || /^$/ { print; next } { if (++i != n) print }' "$f" > "$t" &&
            mv "$t" "$f" || { rm -f "$t"; fleet_die "could not rewrite $f"; }
          fleet_event sync-exception "rm=line$1"; printf 'removed\t%s\n' "$1" ;;
        *) fleet_die "unknown except verb: $ev" ;;
      esac ;;
    auth)
      sync_need; av=${1:-list}; [ $# -ge 1 ] && shift
      case $av in
        list)
          for v in $N2_VENDORS; do
            sync_auth_optin "$v" && o=opted-in || o=off
            printf '%s\t%s\t%s\t%s\n' "$v" "$(sync_auth_support "$v")" "$o" "$(sync_auth_reason "$v")"
          done ;;
        enable)
          [ -n "${1:-}" ] || fleet_die "usage: agents fleet sync auth enable <vendor>"
          # sync_auth_support answers `unverified` for anything it has not
          # inspected, and an unknown vendor is indistinguishable from an
          # uninspected one. Without this gate `auth enable clade` exited 0,
          # appended `clade` to the opt-in file and printed `auth-optin clade
          # unverified` — and because `auth list` iterates $N2_VENDORS, the
          # bogus line never appears again. The operator reads "enabled" for a
          # provider whose auth is in fact still not shared, forever.
          vendor_known "$1" ||
            fleet_die "unknown vendor: '$1' (known: $N2_VENDORS)"
          s=$(sync_auth_support "$1")
          [ "$s" = unsupported ] && fleet_die "$1 auth cannot be replicated: $(sync_auth_reason "$1")"
          [ "$s" = partial ] ||
            echo "agents: $1 auth portability is $s — $(sync_auth_reason "$1")" >&2
          [ "$s" = partial ] &&
            echo "agents: $1 is only partially portable — $(sync_auth_reason "$1")" >&2
          grep -qx "$1" "$(sync_auth_optin_file)" 2>/dev/null || echo "$1" >> "$(sync_auth_optin_file)"
          fleet_event sync-auth-optin "vendor=$1 support=$s"
          printf 'auth-optin\t%s\t%s\n' "$1" "$s" ;;
        disable)
          [ -n "${1:-}" ] || fleet_die "usage: agents fleet sync auth disable <vendor>"
          # The same typo in the revoking direction is the dangerous one:
          # `auth disable clade` printed `auth-optout clade` and exited 0 while
          # claude stayed opted in and kept replicating credential material.
          # An operator withdrawing consent must not be told it happened when
          # it did not.
          vendor_known "$1" ||
            fleet_die "unknown vendor: '$1' (known: $N2_VENDORS)"
          fo=$(sync_auth_optin_file); t="$fo.$$"
          grep -vx "$1" "$fo" > "$t" 2>/dev/null; mv "$t" "$fo"
          fleet_event sync-auth-optin "vendor=$1 support=off"
          printf 'auth-optout\t%s\n' "$1" ;;
        *) fleet_die "unknown auth verb: $av" ;;
      esac ;;
    help|-h|--help) sync_usage ;;
    *) sync_usage >&2; fleet_die "unknown sync verb: $sv" ;;
  esac
}

tools_usage() {
  cat <<'EOF'
agents fleet tools <verb>

  list                                 the fleet-managed manifest, with the
                                       approval state of each record's commands
  add <name> --version <v> --check <cmd> --install <cmd> [--disruptive]
  rm <name>
  approve <name>                       allow this machine to run the install and
                                       check commands the record now carries
                                       (a peer's new or changed command never
                                       runs here until this is given once)
  status                               per tool: ok | install | update |
                                       pending-approval
  apply                                install/update managed tools now
                                       (exit 1 if any tool failed; a deferral
                                       is not a failure)
  install <name>                       install one tool (refuses unmanaged)
  deferred                             updates held back by an active task
EOF
}

sync_tool_install() (
  sync_need
  sync_res_lock "tools-apply" || exit 1
  trap 'sync_res_unlock "tools-apply"' EXIT
  sync_tool_install_locked "$@"
)

# Internal entry point for preparation while it holds the same admission lock.
sync_tool_install_locked() {
  [ -n "${1:-}" ] || fleet_die "usage: agents fleet tools install <name>"
  # The only single-tool entry point, and it refuses anything the operator
  # has not designated. Reachability is never authorization.
  sync_tool_managed "$1" ||
    fleet_die "$1 is not fleet-managed — add it first with 'agents fleet tools add'"
  l=$(sync_tool_line "$1") || fleet_die "$1 is no longer fleet-managed"
  st=$(sync_tool_state "$1" "$l")
  [ "$st" = ok ] && { printf 'ok\t%s\n' "$1"; return 0; }
  # Naming the tool is not approving its command. A record that arrived
  # from a peer carrying an installer this machine never agreed to run is
  # refused here exactly as it is in `apply`, with the approval step named.
  if [ "$st" = pending-approval ]; then
    fleet_event tool-pending-approval "tool=$1"
    printf 'pending-approval\t%s\n' "$1"
    printf "run 'agents fleet tools approve %s' to allow its install command\n" "$1" >&2
    return 1
  fi
  # Naming a tool explicitly is not permission to interrupt running work.
  # Same rule as `tools apply`: disruptive + busy means defer, not force.
  busy=$(sync_tasks_active)
  if [ "$(sync_tool_field "$l" 5)" = disruptive ] && [ "$busy" -gt 0 ]; then
    d=$(sync_tools_deferred); mkdir -p "$(dirname "$d")" 2>/dev/null
    grep -q "^$1	" "$d" 2>/dev/null || printf '%s\t%s\n' "$1" "$st" >> "$d"
    fleet_event tool-deferred "tool=$1 want=$st active_tasks=$busy"
    printf 'deferred\t%s\t%s\tactive_tasks=%s\n' "$1" "$st" "$busy"; return 0
  fi
  if sh -c "$(sync_tool_value "$l" 4)" >/dev/null 2>&1 && [ "$(sync_tool_state "$1" "$l")" = ok ]; then
    fleet_event tool-applied "tool=$1 action=$st"; printf '%s\t%s\n' "$st" "$1"
  else
    fleet_event tool-failed "tool=$1 action=$st"; printf 'failed\t%s\t%s\n' "$1" "$st"; return 1
  fi
}

cmd_fleet_tools() {
  set +e
  tv=${1:-list}; [ $# -ge 1 ] && shift
  # Usage and a mistyped verb must answer before the identity check, the way
  # `fleet sync` already does: a machine that has not run `fleet init` could
  # not read its own help, which is exactly when an operator needs it.
  case $tv in
    help|-h|--help) tools_usage; return 0 ;;
    list|add|rm|approve|status|apply|install|deferred) ;;
    *) tools_usage >&2; fleet_die "unknown tools verb: $tv" ;;
  esac
  sync_need
  f=$(sync_tools_manifest)
  case $tv in
    list)
      while IFS= read -r line; do
        case $line in ''|'#'*) continue ;; esac
        if sync_tool_line_ok "$line"; then
          ln=$(sync_tool_field "$line" 1); ap=approved
          sync_tool_approved "$ln" "$line" || ap=pending-approval
          printf '%s|%s|%s|%s|%s|%s\n' "$ln" \
                 "$(sync_tool_value "$line" 2)" "$(sync_tool_value "$line" 3)" \
                 "$(sync_tool_value "$line" 4)" "$(sync_tool_field "$line" 5)" "$ap"
        else
          printf 'invalid|%s\n' "$(printf '%s' "$line" | cut -d'|' -f1)"
        fi
      done < "$f" 2>/dev/null || true ;;
    add)
      [ -n "${1:-}" ] || fleet_die "usage: agents fleet tools add <name> --version <v> --check <cmd> --install <cmd> [--disruptive]"
      n=$1; shift; ver=; chk=; inst=; dis=
      # An option that swallows the following flag as its value is the quiet
      # version of a typo. `--install --disruptive` used to store an installer
      # literally named "--disruptive", report `managed`, exit 0, and drop the
      # disruptive flag — so a genuinely disruptive update lost the one marker
      # that holds it back while a task is running. A missing value at the end
      # of the line died with a raw `$2: unbound variable` instead of a usage
      # message. A value is required, and it may not itself be an option: no
      # version string and no runnable command begins with `--`.
      while [ $# -gt 0 ]; do case $1 in
        --version|--check|--install)
          o=$1
          [ $# -ge 2 ] || fleet_die "$o needs a value"
          case $2 in --*) fleet_die "$o needs a value, but got the option $2" ;; esac
          case $o in --version) ver=$2 ;; --check) chk=$2 ;; --install) inst=$2 ;; esac
          shift 2 ;;
        --disruptive) dis=disruptive; shift ;;
        *) fleet_die "unknown option: $1" ;; esac; done
      case $n in *'|'*|*'%'*|'') fleet_die "invalid tool name: $n" ;; esac
      case $n in *'	'*) fleet_die "invalid tool name: $n" ;; esac
      [ -n "$inst" ] || fleet_die "a managed tool needs --install (this is the authorization)"
      # And --check, which is how every later pass decides whether to act and
      # whether the installer actually did what it claimed.
      [ -n "$chk" ] || fleet_die "a managed tool needs --check (this is how its version is read)"
      # The dedupe rewrite and the append were both unchecked, so a manifest
      # that could not be written (read-only directory, full disk, a stale
      # root-owned file) still printed `managed <tool>` and exited 0 while
      # nothing was stored. `add` is how the operator grants install authority,
      # and the answer has to be the truth: a tool reported managed but absent
      # from the manifest is never installed or updated by any later pass, and
      # `tools list` gives no hint that the grant went nowhere. Rewrite through
      # a temp file that must survive, then read the record back before saying
      # it took.
      # Under the manifest's resource lock, and as one rename: a pull landing
      # between a filter and an append would otherwise be silently undone and
      # the loss pushed out as an ordinary edit.
      sync_res_lock "$SYNC_TOOLS_ADDR" || fleet_die "tool manifest is busy — $n is not managed"
      t="$f.$$"
      { [ -e "$f" ] && awk -F'|' -v n="$n" '$1!=n' "$f"
        # Escaped: a pipeline in --install or --check is a normal command, not
        # a way to shift the disruptive flag out of its field.
        printf '%s|%s|%s|%s|%s\n' "$n" "$(sync_tool_enc "$ver")" "$(sync_tool_enc "$chk")" \
               "$(sync_tool_enc "$inst")" "$dis"; } > "$t" 2>/dev/null && mv "$t" "$f" ||
        { rm -f "$t" 2>/dev/null; sync_res_unlock "$SYNC_TOOLS_ADDR"; fleet_die "could not write $f — $n is not managed"; }
      sync_res_unlock "$SYNC_TOOLS_ADDR"
      awk -F'|' -v n="$n" '$1==n{found=1} END{exit !found}' "$f" 2>/dev/null ||
        fleet_die "$n did not reach $f — it is not managed"
      # Typing the command here IS the approval: `tools add` is a local
      # operator action, so the record it stores is approved on this machine
      # and applies without a second step. Every other machine receives the
      # designation and decides for itself.
      nl=$(printf '%s|%s|%s|%s|%s' "$n" "$(sync_tool_enc "$ver")" "$(sync_tool_enc "$chk")" "$(sync_tool_enc "$inst")" "$dis")
      { sync_tool_approve "$n" "$nl" ||
            fleet_die "could not record the approval for $n — it will not run here"; }
      fleet_event tool-managed "tool=$n version=$ver disruptive=${dis:-no}"
      printf 'managed\t%s\t%s\n' "$n" "${ver:-any}" ;;
    rm)
      # `tools rm` is how the operator withdraws install authority. A typo that
      # matched no record used to print "unmanaged" and exit 0 while the real
      # tool stayed in the manifest and kept installing on every tick, so the
      # name has to exist before anything is rewritten. Matching is on the
      # record's first field alone, so an invalid record can still be removed.
      [ -n "${1:-}" ] || fleet_die "usage: agents fleet tools rm <name>"
      sync_res_lock "$SYNC_TOOLS_ADDR" || fleet_die "tool manifest is busy — $1 is still managed"
      awk -F'|' -v n="$1" '$1==n{found=1} END{exit !found}' "$f" 2>/dev/null ||
        { sync_res_unlock "$SYNC_TOOLS_ADDR"; fleet_die "$1 is not fleet-managed; run 'agents fleet tools list'"; }
      t="$f.$$"; awk -F'|' -v n="$1" '$1!=n' "$f" > "$t" && mv "$t" "$f" ||
        { rm -f "$t"; sync_res_unlock "$SYNC_TOOLS_ADDR"; fleet_die "could not rewrite $f"; }
      sync_res_unlock "$SYNC_TOOLS_ADDR"
      # Withdrawing the grant has to withdraw the pending update with it. The
      # deferred list is appended to by `tools install` and is only rebuilt by
      # `tools apply`, so on a machine whose tick is not running the record
      # outlived the authorization: `tools deferred` kept naming the tool and
      # the tick kept printing `tools-retry 1` for an update that can never be
      # applied, because `apply` skips anything absent from the manifest. An
      # operator reading a pending update that will never happen is the same
      # false state `rm <typo>` was fixed for.
      d=$(sync_tools_deferred)
      if [ -s "$d" ]; then
        dt="$d.$$"; awk -F'\t' -v n="$1" '$1!=n' "$d" > "$dt" && mv "$dt" "$d" ||
          { rm -f "$dt" 2>/dev/null; fleet_die "could not rewrite $d"; }
      fi
      # The grant is gone, so the standing permission to run its commands goes
      # with it: a later re-designation from any machine is a fresh decision.
      sync_tool_approval_forget "$1" || fleet_die "could not rewrite $(sync_tools_approved_file)"
      fleet_event tool-unmanaged "tool=$1"; printf 'unmanaged\t%s\n' "$1" ;;
    approve)
      [ -n "${1:-}" ] || fleet_die "usage: agents fleet tools approve <name>"
      al=$(sync_tool_line "$1") ||
        fleet_die "$1 is not fleet-managed; run 'agents fleet tools list'"
      # Approving the record as it stands right now. If a peer changes the
      # install command afterwards, the key changes with it and the new command
      # waits for its own approval rather than inheriting this one.
      sync_tool_approve "$1" "$al" || fleet_die "could not record the approval for $1"
      fleet_event tool-approved "tool=$1"
      printf 'approved\t%s\n' "$1" ;;
    status)
      while IFS= read -r line; do
        case $line in ''|'#'*) continue ;; esac
        n=$(printf '%s' "$line" | cut -d'|' -f1)
        if sync_tool_line_ok "$line"; then
          printf '%s\t%s\n' "$n" "$(sync_tool_state "$n")"
        else printf '%s\tinvalid\n' "$n"; fi
      done < "$f" ;;
    apply) sync_tools_apply ;;
    install) sync_tool_install "$@" ;;
    deferred) cat "$(sync_tools_deferred)" 2>/dev/null || true ;;
    *) tools_usage >&2; fleet_die "unknown tools verb: $tv" ;;
  esac
}

# Usage observations use a separate bounded journal. Only the authenticated
# origin exports its observations; matching profile labels never merge accounts.
fleet_handle_usage_export() {
  fleet_approved "$1" || { echo "ERR not-approved"; return 1; }
  /usr/bin/python3 "$scripts_dir/usage-store.py" --root "$root" --origin "$(fleet_self_id)" export > "$3/out" || { echo "ERR usage-journal"; return 1; }
  fleet_ok "$3/out"
}

fleet_handle_usage_page() {
  fleet_approved "$1" || { echo "ERR not-approved"; return 1; }
  /usr/bin/python3 "$scripts_dir/usage-store.py" --root "$root" --origin "$(fleet_self_id)" export-page --source "$1" < "$2" > "$3/out" || { echo "ERR usage-journal"; return 1; }
  fleet_ok "$3/out"
}

sync_usage_pull() (
  sup_dir=$(mktemp -d "${TMPDIR:-/tmp}/n2usagepull.XXXXXX") || exit 1
  trap 'rm -rf "$sup_dir"' EXIT
  : > "$sup_dir/request"
  for sup_peer in $(fleet_peer_ids); do
    [ "$sup_peer" = "$(fleet_self_id)" ] && continue
    fleet_approved "$sup_peer" || continue
    sup_cursor=$(/usr/bin/python3 "$scripts_dir/usage-store.py" --root "$root" --origin "$(fleet_self_id)" exchange-cursor --source "$sup_peer") || exit 1
    printf '%s' "$sup_cursor" > "$sup_dir/request"
    sup_pages=0
    while [ "$sup_pages" -lt 8 ]; do
      sup_pages=$((sup_pages + 1))
      fleet_call "$sup_peer" usage-page "$sup_dir/request" > "$sup_dir/events" 2>/dev/null || break
      sup_cursor=$(/usr/bin/python3 "$scripts_dir/usage-store.py" --root "$root" --origin "$(fleet_self_id)" import-page --source "$sup_peer" --cursor "$sup_cursor" < "$sup_dir/events") || { fleet_event usage-sync-error "peer=$sup_peer invalid-page"; break; }
      [ -n "$sup_cursor" ] || break
      printf '%s' "$sup_cursor" > "$sup_dir/request"
    done
  done
)
