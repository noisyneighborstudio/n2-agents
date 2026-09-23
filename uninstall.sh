#!/bin/zsh
# Removes "N2 Agents.app" (and a pre-rename N2Agents.app) and everything install.sh / the tray wired up: shell
# helper lines (zsh/bash), the fish conf.d stub, the `agents` PATH symlink,
# Warp launch configs, tray defaults — and un-migrates every vendor dot dir
# that `agents use` turned into a symlink, so plain `claude`/`codex`/… keep
# working afterwards.
# Profiles (cloned apps, logins, CLI configs) are listed but only removed if
# you pass --purge. Your original default config is always restored, never
# purged.
set -euo pipefail
setopt null_glob

mkdir -p "$HOME/.n2-agents"
shim_lock="$HOME/.n2-agents/.shims.lock"
attempts=0
until /usr/bin/shlock -f "$shim_lock" -p $$; do
  (( attempts += 1 ))
  (( attempts < 100 )) || { echo "✗ Timed out waiting for profile command sync" >&2; exit 1; }
  sleep 0.1
done
cleanup_shim_lock() { rm -f "$shim_lock" }
trap cleanup_shim_lock EXIT
trap 'exit 1' HUP INT TERM

# N2Agents.app is the pre-rename bundle; Sparkle updates keep an install there.
apps_dirs=("/Applications/N2 Agents.app" "/Applications/N2Agents.app")
pkill -f '/Contents/MacOS/N2 Agents$' 2>/dev/null || true
pkill -f N2AgentsTray 2>/dev/null || true
for a in $apps_dirs; do
  [[ -e $a ]] || continue
  rm -rf "$a"
  echo "✓ Removed ${a:t}"
done

# Un-migrate the global switch for every vendor: put the real dot dir back.
#
# An ADOPTED Default slot is itself a symlink into ~/.claude-profiles (owned by
# the separate `claudes` app). Moving that would hand one app's state to the
# other, so in that case we only drop our own symlink and leave the target be.
typeset -A vendor_dots
vendor_dots=(
  claude   "$HOME/.claude"
  codex    "$HOME/.codex"
  grok     "$HOME/.grok"
  gemini   "$HOME/.gemini"
  cursor   "$HOME/.cursor"
  opencode "$HOME/.config/opencode"
  muse     "$HOME/.config/muse"
)
for vendor dot in ${(kv)vendor_dots}; do
  [[ -L $dot ]] || continue
  slot="$HOME/.n2-agents/Default/$vendor"
  [[ $vendor == (opencode|muse) ]] && slot="$HOME/.n2-agents/Default/$vendor/$vendor"
  rm "$dot"
  if [[ -L $slot ]]; then
    echo "✓ Removed $dot symlink (Default was adopted from another tool; left its dir alone)"
  elif [[ -d $slot ]]; then
    mkdir -p "${dot:h}"
    mv "$slot" "$dot"
    echo "✓ Restored $dot (moved the migrated Default slot back)"
  else
    echo "✓ Removed dangling $dot symlink (no migrated Default to restore)"
  fi
done

# Filter the exact installed helper lines via a temp file + `cat >`. This writes
# through rc files that are symlinks into a dotfiles repo, which BSD `sed -i`
# refuses to edit.
# Helper lines for either bundle name, plus the PATH line.
drop=()
for a in $apps_dirs; do
  res="$a/Contents/Resources"
  drop+=(-e '[[ -f "'"$res"'/agents.zsh" ]] && source "'"$res"'/agents.zsh"  # n2agents'
         -e '[ -f "'"$res"'/agents.bash" ] && . "'"$res"'/agents.bash"  # n2agents')
done
path_line='export PATH="$HOME/.local/bin:$PATH"  # n2agents-path'
fish_drop=(-e 'fish_add_path "$HOME/.local/bin"  # n2agents-path')
for a in $apps_dirs; do
  res="$a/Contents/Resources"
  fish_drop+=(-e 'test -f "'"$res"'/agents.fish"; and source "'"$res"'/agents.fish"  # n2agents')
done
for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
  if grep -qxF $drop -e "$path_line" "$rc" 2>/dev/null; then
    tmp=$(mktemp)
    grep -vxF $drop -e "$path_line" "$rc" > "$tmp" || true
    cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "✓ Removed shell helper line from ${rc/#$HOME/~}"
  fi
done

fish_stub="$HOME/.config/fish/conf.d/n2agents.fish"
if grep -qxF $fish_drop "$fish_stub" 2>/dev/null; then
  tmp=$(mktemp)
  grep -vxF $fish_drop "$fish_stub" > "$tmp" || true
  if [[ -s $tmp ]]; then
    cat "$tmp" > "$fish_stub"
  else
    rm "$fish_stub"
  fi
  rm -f "$tmp"
  echo "✓ Removed fish helper lines"
fi

# PATH symlinks — the CLI plus the claude-as / claude-<profile> shims, only
# where they actually point into either bundle.
targets=()
for a in $apps_dirs; do targets+=("$a/Contents/Resources/agents" "$a/Contents/Resources/agent-as"); done
for bindir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  # Shims are named <vendor>-<profile>, which we can't enumerate here, so
  # ownership is decided by the symlink TARGET rather than by the name.
  for link in "$bindir"/*(N); do
    [[ -L $link ]] || continue
    target=$(readlink "$link")
    (( ${targets[(Ie)$target]} )) || continue
    rm "$link"
    echo "✓ Removed $link"
  done
done
rm -f "$HOME/.n2-agents/.bin-dir"

rm -f "$HOME/.warp/launch_configurations"/n2agents-*.yaml
defaults delete dev.sethwebster.n2agents 2>/dev/null || true

apps=(/Applications/Claude-*.app)
cfgs=("$HOME/.n2-agents"/*(N))

if [[ ${1:-} == "--purge" ]]; then
  for app in $apps; do rm -rf "$app"; echo "✓ Removed $app"; done
  for d in "$HOME/Library/Application Support"/Claude-*(N); do rm -rf "$d"; echo "✓ Removed $d"; done
  # Only our own root: ~/.claude-profiles belongs to the separate `claudes` app,
  # and adopted slots are symlinks into it that must outlive this uninstall.
  rm -rf "$HOME/.n2-agents"
  echo "✓ Removed N2 Agents profile configs"
elif (( ${#apps} + ${#cfgs} > 0 )); then
  echo ""
  echo "Profiles left in place (remove with: ./uninstall.sh --purge):"
  for app in $apps; do echo "  $app"; done
  (( ${#cfgs} > 0 )) && echo "  ~/.n2-agents/"
fi
