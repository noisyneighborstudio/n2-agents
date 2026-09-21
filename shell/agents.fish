# N2 Agents shell helper for fish — tab completion only.
#
# The commands themselves (`agents`, `<vendor>-as`, `<vendor>-<profile>`) are
# real executables on PATH, installed by `agents shims`, so every app, editor
# and script gets them — not just shells that sourced this file.

set -l _n2agents_bin_file "$HOME/.n2-agents/.bin-dir"
if test -r $_n2agents_bin_file
    read -l _n2agents_bin_dir < $_n2agents_bin_file
    if contains -- $_n2agents_bin_dir /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; and test -d $_n2agents_bin_dir
        contains -- $_n2agents_bin_dir $PATH; or set -gx PATH $_n2agents_bin_dir $PATH
    end
end

function __n2agents_vendors
    agents porcelain 2>/dev/null | awk -F\t '$1=="V" && $3=="1" {print $2}'
end

complete -c agents -f -n __fish_use_subcommand \
    -a 'list vendors active use run best new delete repatch adopt sessions transfer fleet desktop shims porcelain profiles version help'
complete -c agents -f -n '__fish_seen_subcommand_from fleet' -a 'init id invite join pair pending approve deny revoke discover reconcile rehost route roster peers ping status send serve help'
complete -c agents -f -n 'not __fish_use_subcommand; and not __fish_seen_subcommand_from fleet' \
    -a '(agents profiles 2>/dev/null) --next --best'
complete -c agents -f -l vendor -a '(__n2agents_vendors)'
complete -c agents -f -l vendors -a '(__n2agents_vendors)'

for v in claude codex grok gemini cursor opencode
    complete -c "$v-as" -f -a '(agents profiles 2>/dev/null) --next --best'
end
