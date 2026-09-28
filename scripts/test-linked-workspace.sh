#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2worktree.XXXXXX")
trap 'rm -rf "$base"' EXIT
# Synthetic git history only; no provider or user repository is modified.
git init -q "$base/main"
git -C "$base/main" config user.name Fixture
git -C "$base/main" config user.email fixture@example.invalid
printf 'original\n' > "$base/main/edit.txt"
printf 'remove\n' > "$base/main/remove.txt"
git -C "$base/main" add .
git -C "$base/main" commit -qm initial
git -C "$base/main" worktree add -qb task "$base/work"
printf 'staged\n' > "$base/work/edit.txt"
git -C "$base/work" add edit.txt
printf 'unstaged\n' >> "$base/work/edit.txt"
rm "$base/work/remove.txt"
printf 'new\n' > "$base/work/untracked.txt"
git -C "$base/work" status --porcelain > "$base/before"
printf '#!/bin/sh\ntouch "%s"\n' "$base/hook-ran" > "$base/fsmonitor"
chmod +x "$base/fsmonitor"
git -C "$base/work" config core.fsmonitor "$base/fsmonitor"
. "$repo/fleet-exec.sh"
exec_ws_pack "$base/work" "$base/workspace.tar"
[ ! -e "$base/hook-ran" ]
echo 'ok workspace packing does not execute source fsmonitor hooks'
mkdir "$base/received"
exec_ws_unpack "$base/workspace.tar" "$base/received"
# Remove access to all origin metadata before testing the received repository.
mv "$base/main" "$base/main-offline"
git -C "$base/received" status --porcelain > "$base/after"
cmp "$base/before" "$base/after"
[ "$(git -C "$base/received" show :edit.txt)" = staged ]
grep -q unstaged "$base/received/edit.txt"
[ ! -e "$base/received/remove.txt" ]
grep -q new "$base/received/untracked.txt"
git -C "$base/received" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'remote staged change'
echo 'ok linked worktree preserves index and dirty files and supports Git without the origin'
