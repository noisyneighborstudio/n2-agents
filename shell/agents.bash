# N2 Agents shell helper for bash — tab completion only.
#
# The commands themselves (`agents`, `<vendor>-as`, `<vendor>-<profile>`) are
# real executables on PATH, installed by `agents shims`, so every app, editor
# and script gets them — not just shells that sourced this file.

_n2agents_bin_file="$HOME/.n2-agents/.bin-dir"
if [ -r "$_n2agents_bin_file" ]; then
  IFS= read -r _n2agents_bin_dir < "$_n2agents_bin_file"
  case $_n2agents_bin_dir in
    /opt/homebrew/bin|/usr/local/bin|"$HOME/.local/bin")
      case :$PATH: in *:"$_n2agents_bin_dir":*) ;; *) export PATH="$_n2agents_bin_dir:$PATH" ;; esac
      ;;
  esac
fi
unset _n2agents_bin_file _n2agents_bin_dir

_n2agents_vendors() {
  agents porcelain 2>/dev/null | awk -F'\t' '$1=="V" && $3=="1" {print $2}'
}

_n2agents_complete() {
  local prev=${COMP_WORDS[COMP_CWORD-1]} words
  if [ "$COMP_CWORD" -eq 1 ]; then
    words="list vendors active use run best new delete adopt sessions transfer fleet desktop shims loop porcelain profiles version help"
  elif [ "${COMP_WORDS[1]}" = "fleet" ]; then
    if [ "$COMP_CWORD" -eq 2 ]; then
      words="init id invite join pair pending approve deny revoke discover reconcile rehost route roster peers ping status sync tools send serve help"
    elif [ "$COMP_CWORD" -eq 3 ]; then
      case ${COMP_WORDS[2]} in
        sync) words="now tick auto service status scope conflicts show resolve except auth categories import-local" ;;
        tools) words="list add rm approve status apply install deferred" ;;
      esac
    fi
  elif [ "$prev" = "--vendor" ] || [ "$prev" = "--vendors" ]; then
    words="$(_n2agents_vendors)"
  else
    words="$(agents profiles 2>/dev/null) --next --best --vendor"
  fi
  COMPREPLY=($(compgen -W "$words" -- "${COMP_WORDS[COMP_CWORD]}"))
}
complete -F _n2agents_complete agents

_n2agents_as_complete() {
  COMPREPLY=($(compgen -W "$(agents profiles 2>/dev/null) --next --best" -- "${COMP_WORDS[COMP_CWORD]}"))
}
for _n2agents_v in claude codex grok cursor opencode muse; do
  complete -F _n2agents_as_complete "$_n2agents_v-as"
done
unset _n2agents_v
