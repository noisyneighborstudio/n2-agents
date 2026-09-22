# N2 Agents shell helper for zsh — tab completion only.
#
# The commands themselves (`agents`, `<vendor>-as`, `<vendor>-<profile>`) are
# real executables on PATH, installed by `agents shims`, so every app, editor
# and script gets them — not just shells that sourced this file.

_n2agents_bin_file="$HOME/.n2-agents/.bin-dir"
if [[ -r $_n2agents_bin_file ]]; then
  IFS= read -r _n2agents_bin_dir < "$_n2agents_bin_file"
  case $_n2agents_bin_dir in
    /opt/homebrew/bin|/usr/local/bin|"$HOME/.local/bin")
      [[ -d $_n2agents_bin_dir && :$PATH: != *":$_n2agents_bin_dir:"* ]] \
        && export PATH="$_n2agents_bin_dir:$PATH"
      ;;
  esac
fi
unset _n2agents_bin_file _n2agents_bin_dir

_n2agents_profiles() {
  local -a profiles
  profiles=(--next --best ${(f)"$(agents profiles 2>/dev/null)"})
  _describe 'profile' profiles
}

# `--vendor` takes a vendor id; everything else takes a profile.
_n2agents_cli() {
  if (( CURRENT == 2 )); then
    _values 'command' list vendors active use run best new delete repatch adopt \
      sessions transfer fleet desktop shims porcelain profiles version help
  elif [[ ${words[2]} == fleet ]]; then
    if (( CURRENT == 3 )); then
      _values 'fleet verb' init id invite join pair pending approve deny revoke discover reconcile rehost route roster peers ping status sync tools send serve help
    elif (( CURRENT == 4 )); then
      case ${words[3]} in
        sync) _values 'sync verb' now tick auto service status scope conflicts show resolve except auth ;;
        tools) _values 'tools verb' list add rm status apply install deferred ;;
      esac
    fi
  elif [[ ${words[CURRENT-1]} == (--vendor|--vendors) ]]; then
    local -a vendors
    vendors=(${(f)"$(agents porcelain 2>/dev/null | awk -F'\t' '$1=="V" && $3=="1" {print $2}')"})
    _describe 'vendor' vendors
  else
    _n2agents_profiles
  fi
}

if (( $+functions[compdef] )); then
  compdef _n2agents_cli agents
  for _n2agents_v in claude codex grok gemini cursor opencode; do
    compdef _n2agents_profiles "$_n2agents_v-as" 2>/dev/null
  done
  unset _n2agents_v
fi
