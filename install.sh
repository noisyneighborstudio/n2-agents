#!/bin/zsh
# Installs "N2 Agents.app": prefers the latest signed GitHub release; falls back
# to building from source (requires Xcode Command Line Tools).
# Force a source build with: N2_FROM_SOURCE=1 ./install.sh
# Install a zip you already have (a build copied from another Mac, or a
# release downloaded by hand): N2_APP_ZIP=/path/to/N2Agents.zip ./install.sh
set -euo pipefail

REPO="noisyneighborstudio/n2-agents"
# Where releases are published: N2_UPDATES_REPO in updates.env. Copied, not
# sourced — this script runs piped, with no checkout. test.sh keeps them equal.
UPDATES_REPO="noisyneighborstudio/n2-agents"
app="/Applications/N2 Agents.app"
# Before the rename the bundle was N2Agents.app. Sparkle updates keep an
# install's path, so older installs may still live there: this script moves
# them, and everything below treats links into the old path as its own.
legacy_app="/Applications/N2Agents.app"

place_app() {  # built or downloaded bundle
  pkill -f '/Contents/MacOS/N2 Agents$' 2>/dev/null || true
  pkill -f N2AgentsTray 2>/dev/null || true
  rm -rf "$app" "$legacy_app"
  ditto "$1" "$app"
}

install_from_zip() {  # zip holding the app bundle
  local tmp
  tmp=$(mktemp -d)
  ditto -xk "$1" "$tmp/unzipped" || return 1
  # Releases from before the rename carry N2Agents.app; take whichever it is.
  local bundles=("$tmp/unzipped"/*.app(N))
  (( ${#bundles} == 1 )) || return 1
  # Signed but not notarized; installed by script, so clear the download quarantine.
  xattr -dr com.apple.quarantine "$bundles[1]" 2>/dev/null || true
  place_app "$bundles[1]"
  rm -rf "$tmp"
}

install_from_release() {
  local tmp url
  url=$(curl -fsSL "https://api.github.com/repos/$UPDATES_REPO/releases/latest" \
        | /usr/bin/python3 -c "import json,sys; r=json.load(sys.stdin); print(next((a['browser_download_url'] for a in r.get('assets',[]) if a['name']=='N2Agents.zip'), ''))" 2>/dev/null) || return 1
  [[ -n $url ]] || return 1
  echo "Installing from latest release…"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/N2Agents.zip" || return 1
  install_from_zip "$tmp/N2Agents.zip" || return 1
  rm -rf "$tmp"
}

install_from_source() {
  if [[ -f ${0:A:h}/tray/build.sh ]]; then
    cd "${0:A:h}"
  else
    local tmp
    tmp=$(mktemp -d)
    echo "Cloning $REPO…"
    git clone "https://github.com/$REPO" "$tmp/n2-agents"   # full clone: tags stamp the version
    cd "$tmp/n2-agents"
  fi
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required for source builds. Starting install — re-run this script after it finishes."
    xcode-select --install
    exit 1
  fi
  ./tray/build.sh
  place_app "tray/build/N2 Agents.app"
}

if [[ -n ${N2_APP_ZIP:-} ]]; then
  echo "Installing from $N2_APP_ZIP…"
  install_from_zip "$N2_APP_ZIP" || { echo "✗ $N2_APP_ZIP doesn't hold one N2 Agents app bundle" >&2; exit 1; }
elif [[ ${N2_FROM_SOURCE:-0} == 1 ]]; then
  install_from_source
elif ! install_from_release; then
  echo "No release available — building from source…"
  install_from_source
fi

open "$app"

# Shell helpers: tab completion for agents / <vendor>-as, for every shell the
# user actually has (zsh, bash, fish). The commands themselves go on PATH
# below. Sourced from the installed app so there's one stable path; the guards
# make the lines inert if N2 Agents is ever removed.
res="$app/Contents/Resources"
legacy_res="$legacy_app/Contents/Resources"
helper_lines() {  # resources dir -> the zsh, bash and fish lines that source it
  print -r -- '[[ -f "'"$1"'/agents.zsh" ]] && source "'"$1"'/agents.zsh"  # n2agents'
  print -r -- '[ -f "'"$1"'/agents.bash" ] && . "'"$1"'/agents.bash"  # n2agents'
  print -r -- 'test -f "'"$1"'/agents.fish"; and source "'"$1"'/agents.fish"  # n2agents'
}
# Drop lines pointing at the pre-rename bundle so the current ones go in below.
# Temp file + `cat >` writes through rc files symlinked into a dotfiles repo.
legacy_lines=("${(@f)$(helper_lines "$legacy_res")}")
for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.config/fish/conf.d/n2agents.fish"; do
  [[ -f $rc && -w $rc ]] || continue
  grep -qxF -e "$legacy_lines[1]" -e "$legacy_lines[2]" -e "$legacy_lines[3]" "$rc" || continue
  tmp_rc=$(mktemp)
  grep -vxF -e "$legacy_lines[1]" -e "$legacy_lines[2]" -e "$legacy_lines[3]" "$rc" > "$tmp_rc" || true
  cat "$tmp_rc" > "$rc"
  rm -f "$tmp_rc"
done

zsh_line='[[ -f "'"$res"'/agents.zsh" ]] && source "'"$res"'/agents.zsh"  # n2agents'
if [[ -w $HOME/.zshrc || ! -e $HOME/.zshrc ]] && ! grep -qF '# n2agents' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n%s\n' "$zsh_line" >> "$HOME/.zshrc"
  echo "✓ Shell helper added to ~/.zshrc"
fi

bash_line='[ -f "'"$res"'/agents.bash" ] && . "'"$res"'/agents.bash"  # n2agents'
for rc in "$HOME/.bash_profile" "$HOME/.bashrc"; do
  [[ -f $rc && -w $rc ]] || continue
  grep -qF '# n2agents' "$rc" 2>/dev/null && continue
  printf '\n%s\n' "$bash_line" >> "$rc"
  echo "✓ Shell helper added to ${rc/#$HOME/~}"
done

if [[ -d $HOME/.config/fish ]]; then
  mkdir -p "$HOME/.config/fish/conf.d"
  fish_stub="$HOME/.config/fish/conf.d/n2agents.fish"
  fish_line='test -f "'"$res"'/agents.fish"; and source "'"$res"'/agents.fish"  # n2agents'
  if ! grep -qF "$fish_line" "$fish_stub" 2>/dev/null; then
    printf '\n%s\n' "$fish_line" >> "$fish_stub"
  fi
  echo "✓ Shell helper added to ~/.config/fish/conf.d/n2agents.fish"
fi

# `agents` CLI on PATH for every shell (bash/fish/scripts), not just zsh.
cli_src="$res/agents"
legacy_cli="$legacy_res/agents"
owned_link() { [[ -L $1 ]] && [[ $(readlink "$1") == "$cli_src" || $(readlink "$1") == "$legacy_cli" ]] }
linked_bin=""
link_collision=0
active_agents=$(command -v agents 2>/dev/null || true)
if [[ -n $active_agents && $active_agents != "$cli_src" && $active_agents != "$legacy_cli" ]]; then
  if ! owned_link "$active_agents"; then
    echo "✗ The active agents command at $active_agents isn't owned by N2 Agents." >&2
    link_collision=1
  fi
fi
candidate_bins=()
for bindir in ${(s.:.)PATH} "$HOME/.local/bin"; do
  case "$bindir" in
    /opt/homebrew/bin|/usr/local/bin|"$HOME/.local/bin") ;;
    *) continue ;;
  esac
  (( ${candidate_bins[(Ie)$bindir]} )) || candidate_bins+=("$bindir")
done
for bindir in $candidate_bins; do
  [[ $link_collision == 0 ]] || break
  [[ $bindir == "$HOME/.local/bin" ]] && mkdir -p "$bindir" 2>/dev/null
  if [[ -d $bindir && -w $bindir ]]; then
    dest="$bindir/agents"
    if [[ -e $dest || -L $dest ]] && ! owned_link "$dest"; then
      echo "✗ $dest exists and isn't owned by N2 Agents; leaving it unchanged." >&2
      link_collision=1
      break
    fi
    ln -sf "$cli_src" "$bindir/agents"
    linked_bin="$bindir"
    echo "✓ agents CLI linked at $bindir/agents"
    break
  fi
done

if [[ -z $linked_bin ]]; then
  if [[ $link_collision == 1 ]]; then
    echo "✗ Resolve the active agents command collision, then run install.sh again." >&2
  else
    echo "✗ Couldn't find a writable PATH directory for the agents CLI." >&2
  fi
fi

if [[ $linked_bin == "$HOME/.local/bin" && :$PATH: != *":$HOME/.local/bin:"* ]]; then
  path_line='export PATH="$HOME/.local/bin:$PATH"  # n2agents-path'
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [[ $rc == "$HOME/.zshrc" || -f $rc ]] || continue
    [[ -w $rc || ! -e $rc ]] || continue
    grep -qF '# n2agents-path' "$rc" 2>/dev/null && continue
    printf '\n%s\n' "$path_line" >> "$rc"
    echo "✓ ~/.local/bin added to ${rc/#$HOME/~}"
  done
  fish_stub="$HOME/.config/fish/conf.d/n2agents.fish"
  fish_path_line='fish_add_path "$HOME/.local/bin"  # n2agents-path'
  if [[ -f $fish_stub ]] && ! grep -qF "$fish_path_line" "$fish_stub"; then
    printf '\n%s\n' "$fish_path_line" >> "$fish_stub"
    echo "✓ ~/.local/bin added to fish PATH"
  fi
  export PATH="$HOME/.local/bin:$PATH"
fi

if [[ -n $linked_bin ]]; then
  mkdir -p "$HOME/.n2-agents"
  printf '%s\n' "$linked_bin" > "$HOME/.n2-agents/.bin-dir"
fi

# <vendor>-as / <vendor>-<profile> as real executables, so apps, editors and
# scripts that never source a shell rc can pin a profile too.
if [[ -n $linked_bin ]]; then
  "$cli_src" shims || echo "✗ Couldn't create profile commands — run 'agents shims' once a PATH dir is writable." >&2
fi

echo ""
echo "✓ Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null | sed 's/^/v/'). Look for the N2 Agents icon in the menu bar."
echo "  Optional: add N2 Agents to System Settings → Login Items."
