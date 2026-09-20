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
#   env         env var that relocates that dir, or "" if the vendor has none
#   isolation   derived from `env`:
#                 env   — profiles run CONCURRENTLY, each pinned per-process
#                 swap  — no env var exists, so only the symlink swap works and
#                         exactly one profile can be active at a time
#   desktop     clone  — a macOS bundle we copy per profile (Claude)
#               launch — the CLI opens its own desktop app (Codex)
#               none
#   usage       oauth  — server-side quota we can query (Claude only, today)
#               none
#   sessions    layout of resumable transcripts, for list/transfer
#
# POSIX sh on purpose — sourced by `agents`, which any shell may invoke.

# Order matters: it's the display order everywhere, and the first installed
# vendor is the default when a command needs one and the user didn't say.
N2_VENDORS="claude codex grok gemini cursor opencode hermes"

vendor_known() {
  for v in $N2_VENDORS; do [ "$v" = "$1" ] && return 0; done
  return 1
}

vendor_label() {
  case $1 in
    claude)   echo "Claude Code" ;;
    codex)    echo "Codex" ;;
    grok)     echo "Grok" ;;
    gemini)   echo "Gemini" ;;
    cursor)   echo "Cursor" ;;
    opencode) echo "opencode" ;;
    hermes)   echo "Hermes" ;;
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
    gemini)   echo "$HOME/.gemini" ;;
    cursor)   echo "$HOME/.cursor" ;;
    opencode) echo "$HOME/.config/opencode" ;;
    hermes)   echo "$HOME/.hermes" ;;
  esac
}

# Env var that repoints the config dir for a single invocation. Empty means the
# vendor hard-codes its path and can only be switched globally via the symlink.
#
# Verified against the shipped binaries, not documentation:
#   claude    CLAUDE_CONFIG_DIR   read by the CLI
#   codex     CODEX_HOME          present in the Rust binary
#   grok      GROK_HOME           present in the Rust binary
#   cursor    CURSOR_CONFIG_DIR   present in the bundled JS
#   opencode  XDG_CONFIG_HOME     standard XDG lookup; we point at the PARENT,
#                                 and opencode appends /opencode itself
#   hermes    HERMES_HOME         read from the environment in hermes_constants.py
#   gemini    (none)              GEMINI_DIR is a source constant equal to
#                                 ".gemini", never read from the environment
vendor_env() {
  case $1 in
    claude)   echo "CLAUDE_CONFIG_DIR" ;;
    codex)    echo "CODEX_HOME" ;;
    grok)     echo "GROK_HOME" ;;
    cursor)   echo "CURSOR_CONFIG_DIR" ;;
    opencode) echo "XDG_CONFIG_HOME" ;;
    hermes)   echo "HERMES_HOME" ;;
    gemini)   echo "" ;;
  esac
}

vendor_isolation() {
  if [ -n "$(vendor_env "$1")" ]; then echo env; else echo swap; fi
}

# opencode reads $XDG_CONFIG_HOME/opencode, so the env var must point one level
# above the slot. Every other vendor's env var names the config dir itself.
vendor_env_value() {  # vendor, slot-dir -> value for vendor_env's variable
  case $1 in
    opencode) dirname "$2" ;;
    *)        echo "$2" ;;
  esac
}

# Where the slot for opencode has to live, given the env var points at its
# parent: the directory must literally be named "opencode".
vendor_slot_name() {
  case $1 in
    opencode) echo "opencode/opencode" ;;
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

vendor_usage() {
  case $1 in
    claude) echo oauth ;;
    *)      echo none ;;
  esac
}

vendor_sessions() {
  case $1 in
    claude) echo projects ;;   # projects/<slug>/<uuid>.jsonl
    codex)  echo sessions ;;   # sessions/<y>/<m>/<d>/rollout-*.jsonl
    *)      echo none ;;
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
    gemini)   echo "npm install -g @google/gemini-cli" ;;
    cursor)   echo "curl https://cursor.com/install -fsS | bash" ;;
    opencode) echo "curl -fsSL https://opencode.ai/install | bash" ;;
    hermes)   echo "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash" ;;
  esac
}

# The file whose presence means "signed in", relative to the config dir. Empty
# when the vendor keeps its token somewhere we can't see from disk:
#   claude    keeps OAuth in the macOS keychain, keyed to the config-dir PATH
#             (see claude_signed_in in `agents`); .credentials.json is the
#             Linux/fallback location and is checked too
#   cursor    stores its session outside CURSOR_CONFIG_DIR (not on disk under
#             ~/.cursor either) — only `cursor-agent status` can tell
#   opencode  writes auth.json under XDG_DATA_HOME, not XDG_CONFIG_HOME, so its
#             login is shared by every profile; vendor_auth_file names the
#             absolute path in that case
vendor_auth_file() {  # vendor, config-dir -> path or ""
  case $1 in
    claude)   echo "$2/.credentials.json" ;;
    codex)    echo "$2/auth.json" ;;
    grok)     echo "$2/auth.json" ;;
    gemini)   echo "$2/oauth_creds.json" ;;
    hermes)   echo "$2/auth.json" ;;
    opencode) echo "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" ;;
    *)        echo "" ;;
  esac
}

# Arguments that start the vendor's own sign-in flow. Gemini has no login
# subcommand: it prompts on first run, so running it bare IS the sign-in.
vendor_login_args() {
  case $1 in
    claude)   echo "auth login" ;;
    codex)    echo "login" ;;
    grok)     echo "login" ;;
    cursor)   echo "login" ;;
    opencode) echo "auth login" ;;
    hermes)   echo "setup" ;;
    gemini)   echo "" ;;
  esac
}

# Some vendors install THEMSELVES inside their config dir (Grok's binary is
# ~/.grok/bin/grok; Hermes' venv is ~/.hermes/hermes-agent). Migrating that
# dir into Default and symlinking back is harmless, but pointing the dot dir at
# any other profile would make the command itself vanish. `switch_vendor`
# refuses that; per-process pinning (grok-work) still works for them.
vendor_install_dir() {  # vendor -> subdir that must stay reachable, or ""
  case $1 in
    grok)   echo "bin" ;;
    hermes) echo "hermes-agent" ;;
    *)      echo "" ;;
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
