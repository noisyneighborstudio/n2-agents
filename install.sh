#!/bin/zsh
# Installs N2Agents.app: prefers the latest signed GitHub release; falls back to
# building from source (requires Xcode Command Line Tools).
# Force a source build with: N2_FROM_SOURCE=1 ./install.sh
set -euo pipefail

REPO="noisyneighborstudio/n2-agents"

install_from_release() {
  local tmp url
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | /usr/bin/python3 -c "import json,sys; r=json.load(sys.stdin); print(next((a['browser_download_url'] for a in r.get('assets',[]) if a['name']=='N2Agents.zip'), ''))" 2>/dev/null) || return 1
  [[ -n $url ]] || return 1
  echo "Installing from latest release…"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/N2Agents.zip" || return 1
  ditto -xk "$tmp/N2Agents.zip" "$tmp" || return 1
  [[ -d "$tmp/N2Agents.app" ]] || return 1
  # Signed but not notarized; installed by script, so clear the download quarantine.
  xattr -dr com.apple.quarantine "$tmp/N2Agents.app" 2>/dev/null || true
  pkill -f N2AgentsTray 2>/dev/null || true
  rm -rf /Applications/N2Agents.app
  ditto "$tmp/N2Agents.app" /Applications/N2Agents.app
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
  pkill -f N2AgentsTray 2>/dev/null || true
  rm -rf /Applications/N2Agents.app
  cp -R tray/build/N2Agents.app /Applications/
}

if [[ ${N2_FROM_SOURCE:-0} == 1 ]]; then
  install_from_source
elif ! install_from_release; then
  echo "No release available — building from source…"
  install_from_source
fi

open /Applications/N2Agents.app

# Shell helpers: tab completion for agents / <vendor>-as, for every shell the
# user actually has (zsh, bash, fish). The commands themselves go on PATH
# below. Sourced from the installed app so there's one stable path; the guards
# make the lines inert if N2 Agents is ever removed.
res="/Applications/N2Agents.app/Contents/Resources"

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
cli_src="/Applications/N2Agents.app/Contents/Resources/agents"
linked_bin=""
link_collision=0
active_agents=$(command -v agents 2>/dev/null || true)
if [[ -n $active_agents && $active_agents != "$cli_src" ]]; then
  if [[ ! -L $active_agents || $(readlink "$active_agents") != "$cli_src" ]]; then
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
    if [[ -e $dest || -L $dest ]] && [[ ! -L $dest || $(readlink "$dest") != "$cli_src" ]]; then
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
echo "✓ Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/N2Agents.app/Contents/Info.plist 2>/dev/null | sed 's/^/v/'). Look for the N2 Agents icon in the menu bar."
echo "  Optional: add N2 Agents to System Settings → Login Items."
