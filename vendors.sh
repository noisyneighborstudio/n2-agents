#!/bin/sh
# vendors.sh — the vendor adapter table for N2 Agents.
#
# Every vendor-specific fact lives here and nowhere else: the rest of the CLI
# is written against these accessors. Adding a lab means adding one case arm to
# each function below — no changes to `agents` itself.
#
# The fields, and why each one exists:
#
#   cli         binary name on PATH; also how we detect "installed"
#   dot         the config dir the CLI uses when nothing overrides it
#   env         env var that relocates that dir, so profiles run CONCURRENTLY,
#               each pinned per process. A lab without one can't be supported.
#   desktop     clone  — a macOS bundle we copy per profile (Claude)
#               launch — the CLI opens its own desktop app (Codex)
#               none
#   usage       oauth    — server-side quota we can query (Claude, Codex, Grok)
#               ondemand — the same, but each read has a cost (Muse mints an
#                          inference key per read), so the tray never polls it:
#                          it reads when the panel opens or on retry
#               none
#   sessions    layout of resumable transcripts, for list/transfer
#   logout/login  the CLI's own sign-out/sign-in subcommands, for `agents login`
#
# POSIX sh on purpose — sourced by `agents`, which any shell may invoke.

# Order matters: it's the display order everywhere, and the first installed
# vendor is the default when a command needs one and the user didn't say.
N2_VENDORS="claude codex grok cursor opencode muse"

# Labs we used to manage. Only cleanup reads this: stale shims get pruned and
# the dot dir symlink turned back into a real dir.
#   gemini  Gemini CLI stopped serving personal accounts (2026-06-18); its
#           successor, Antigravity CLI, keeps its login in the Keychain, out
#           of any dir we could swap
N2_RETIRED_VENDORS="gemini"

vendor_known() {
  for v in $N2_VENDORS; do [ "$v" = "$1" ] && return 0; done
  return 1
}

vendor_label() {
  case $1 in
    claude)   echo "Claude Code" ;;
    codex)    echo "Codex" ;;
    grok)     echo "Grok" ;;
    cursor)   echo "Cursor" ;;
    opencode) echo "opencode" ;;
    muse)     echo "Muse" ;;
    *)        echo "$1" ;;
  esac
}

vendor_cli() {
  case $1 in
    cursor) echo "cursor-agent" ;;
    *)      echo "$1" ;;
  esac
}

# The vendor's default config dir. This is what we migrate into a profile slot
# and replace with a symlink when a profile is made active.
vendor_dot() {
  case $1 in
    claude)   echo "$HOME/.claude" ;;
    codex)    echo "$HOME/.codex" ;;
    grok)     echo "$HOME/.grok" ;;
    cursor)   echo "$HOME/.cursor" ;;
    opencode) echo "$HOME/.config/opencode" ;;
    muse)     echo "$HOME/.config/muse" ;;
  esac
}

# Env var that repoints the config dir for a single invocation.
#
# Verified against the shipped binaries, not documentation:
#   claude    CLAUDE_CONFIG_DIR   read by the CLI
#   codex     CODEX_HOME          present in the Rust binary
#   grok      GROK_HOME           present in the Rust binary
#   cursor    CURSOR_CONFIG_DIR   present in the bundled JS
#   opencode  XDG_CONFIG_HOME     standard XDG lookup; we point at the PARENT,
#                                 and opencode appends /opencode itself
#   muse      XDG_CONFIG_HOME     same as opencode: auth.json lives in
#                                 $XDG_CONFIG_HOME/muse (no MUSE_HOME exists)
vendor_env() {
  case $1 in
    claude)   echo "CLAUDE_CONFIG_DIR" ;;
    codex)    echo "CODEX_HOME" ;;
    grok)     echo "GROK_HOME" ;;
    cursor)   echo "CURSOR_CONFIG_DIR" ;;
    opencode|muse) echo "XDG_CONFIG_HOME" ;;
  esac
}

# Extra env a pinned run needs so the login stays in the slot. Muse keeps its
# sign-in in ONE keychain item (ai.meta.dev.credentials) whatever
# XDG_CONFIG_HOME says, so without this every profile shares one account and
# signing one in signs the others over. The file backend stores it in the
# slot's auth.json instead. Default keeps the keychain: it's the login a plain
# `muse` finds.
vendor_env_extra() {  # vendor, profile
  case $1 in
    muse) [ "$2" = Default ] || echo "TBH_CREDENTIAL_BACKEND=file" ;;
  esac
  true
}

# opencode and muse read $XDG_CONFIG_HOME/<name>, so the env var must point one
# level above the slot. Every other vendor's env var names the config dir itself.
vendor_env_value() {  # vendor, slot-dir -> value for vendor_env's variable
  case $1 in
    opencode|muse) dirname "$2" ;;
    *)        echo "$2" ;;
  esac
}

# Where the slot for an XDG lab has to live, given the env var points at its
# parent: the directory must literally be named after the lab.
vendor_slot_name() {
  case $1 in
    opencode|muse) echo "$1/$1" ;;
    *)        echo "$1" ;;
  esac
}

vendor_desktop() {
  case $1 in
    claude) echo clone ;;
    codex)  echo launch ;;
    *)      echo none ;;
  esac
}

# The lab's desktop app, as people call it — for labs with one.
vendor_desktop_name() {
  case $1 in
    claude) echo "Claude Desktop" ;;
    codex)  echo "Codex" ;;
    *)      echo "" ;;
  esac
}

# The desktop app's bundle id, to find and open it. A `clone` lab's per-profile
# copies carry their own ids; this is the original.
vendor_desktop_bundle() {
  case $1 in
    claude) echo "com.anthropic.claudefordesktop" ;;
    codex)  echo "com.openai.codex" ;;
    *)      echo "" ;;
  esac
}

vendor_usage() {
  case $1 in
    claude|codex|grok) echo oauth ;;
    muse)   echo ondemand ;;
    *)      echo none ;;
  esac
}

vendor_has_usage() { [ "$(vendor_usage "$1")" != none ]; }

vendor_sessions() {
  case $1 in
    claude) echo projects ;;   # projects/<slug>/<uuid>.jsonl
    codex)  echo sessions ;;   # sessions/<y>/<m>/<d>/rollout-*.jsonl
    *)      echo none ;;
  esac
}

# Sign-out / sign-in subcommands, run with the slot pinned. Empty means the
# CLI has none: `agents login` then starts it plainly, and it asks on its own.
vendor_logout() {
  case $1 in
    claude|opencode)    echo "auth logout" ;;
    codex|grok|cursor|muse)  echo "logout" ;;
    *)                  echo "" ;;
  esac
}

vendor_login() {
  case $1 in
    claude|opencode)    echo "auth login" ;;
    codex|grok|cursor|muse)  echo "login" ;;
    *)                  echo "" ;;
  esac
}

# Account a slot is signed in to, read from the vendor's own files; empty when
# unknown. Cheap on purpose — the tray reads it on every refresh.
vendor_account() {  # vendor, slot dir
  case $1 in
    claude) grep -o '"emailAddress": *"[^"]*"' "$2/.claude.json" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"$//' ;;
  esac
  true
}

# Whether a slot holds a login: 0 yes, 1 no, 2 can't tell from outside (the
# CLI keeps it somewhere shared or opaque — Cursor's keychain, opencode's
# XDG data dir). Cheap: profile setup polls it every couple of seconds.
vendor_authed() {  # vendor, slot dir, profile
  case $1 in
    claude)
      # Claude Code keys its keychain entry to the config dir it was pinned to.
      va_svc="Claude Code-credentials-$(printf '%s' "$2" | shasum -a 256 | cut -c1-8)"
      security find-generic-password -s "$va_svc" >/dev/null 2>&1 && return 0
      if [ "$3" = Default ]; then
        security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && return 0
      fi
      [ -s "$2/.credentials.json" ] ;;
    codex|grok) [ -s "$2/auth.json" ] ;;
    muse)
      # A profile's login is the token in its auth.json (the file backend, see
      # vendor_env_extra); Default's auth.json points at the keychain item.
      if [ "$3" = Default ]; then [ -s "$2/auth.json" ]
      else grep -q '"access_token"' "$2/auth.json" 2>/dev/null; fi ;;
    *)          return 2 ;;
  esac
}

# Two-letter tile the panel draws for a lab — N2's own mark, not the lab's.
vendor_monogram() {
  case $1 in
    claude)   echo CC ;;
    codex)    echo CX ;;
    grok)     echo GK ;;
    cursor)   echo CU ;;
    opencode) echo OC ;;
    muse)     echo MU ;;
    *)        printf '%s' "$1" | cut -c1-2 | tr '[:lower:]' '[:upper:]' ;;
  esac
}

# Prints who the CLI is signed in as, run after `agents login` so the terminal
# confirms the account instead of leaving it to guesswork.
vendor_whoami() {
  case $1 in
    claude)   echo "auth status --text" ;;
    codex)    echo "login status" ;;
    cursor)   echo "status" ;;
    opencode) echo "auth list" ;;
    *)        echo "" ;;
  esac
}

vendor_installed() {
  command -v "$(vendor_cli "$1")" >/dev/null 2>&1
}

vendor_install_hint() {
  case $1 in
    claude)   echo "npm install -g @anthropic-ai/claude-code" ;;
    codex)    echo "npm install -g @openai/codex" ;;
    grok)     echo "https://docs.x.ai/docs/grok-cli" ;;
    cursor)   echo "curl https://cursor.com/install -fsS | bash" ;;
    opencode) echo "curl -fsSL https://opencode.ai/install | bash" ;;
    muse)     echo "curl -fsSL https://dev.meta.ai/install.sh | bash" ;;
  esac
}

# Vendors present on this machine, in table order.
# The trailing `true` matters: without it the function inherits the exit status
# of the LAST vendor's check, so a single missing CLI would abort every caller
# running under `set -e`.
vendors_installed() {
  for v in $N2_VENDORS; do
    vendor_installed "$v" && echo "$v"
  done
  true
}
