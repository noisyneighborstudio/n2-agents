#!/bin/sh
# Hostile task and result archives from a signed peer never extract a byte
# outside the destination. Archives are built member by member with Python's
# tarfile and fed to the real exec_ws_unpack; nothing here uses a real peer.
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/n2archive.XXXXXX")
trap 'rm -rf "$base"' EXIT HUP INT TERM
scripts_dir=$repo
. "$repo/fleet-exec.sh"
fail=0
bad() { fail=1; printf 'FAIL %s\n' "$1"; }

/usr/bin/python3 - "$base" <<'PY'
import io, sys, tarfile
base = sys.argv[1]
REG, SYM, LNK, FIFO = tarfile.REGTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE
cases = {
    'refuse-absolute': [(base + '/escaped', REG)],
    'refuse-dotdot': [('../escaped', REG)],
    'refuse-link-absolute': [('link', SYM, base)],
    'refuse-link-dotdot': [('up', SYM, '..')],
    'refuse-link-arrow-name': [('x -> y', SYM, '..')],
    'refuse-write-through-link': [('up', SYM, '..'), ('up/escaped', REG)],
    'refuse-hardlink-out': [('h', LNK, '../outside')],
    'refuse-hardlink-absolute': [('h', LNK, base + '/outside')],
    'refuse-fifo': [('pipe', FIFO)],
    'refuse-newline-name': [('ok\n../escaped', REG)],
    'accept-workspace': [('src', tarfile.DIRTYPE, '', 0o755), ('src/a', REG), ('src/b', SYM, 'a'),
                         ('src/c', LNK, 'src/a'), ('run.sh', REG, '', 0o4755)],
}
for name, members in cases.items():
    with tarfile.open(f'{base}/{name}.tar', 'w', format=tarfile.PAX_FORMAT) as archive:
        for member in members:
            path, kind = member[0], member[1]
            info = tarfile.TarInfo(path)
            info.type, info.linkname = kind, member[2] if len(member) > 2 else ''
            info.mode = member[3] if len(member) > 3 else 0o644
            data = b'x' if kind == REG else b''
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data) if kind == REG else None)
PY
echo outside > "$base/outside"

for archive in "$base"/refuse-*.tar; do
  name=$(basename "$archive" .tar)
  mkdir -p "$base/work/$name"
  if ( cd "$base/work/$name" && exec_ws_unpack "$archive" "$base/dest-$name" ) 2>/dev/null; then
    bad "$name: accepted"
  elif [ -e "$base/dest-$name" ] && [ -n "$(ls -A "$base/dest-$name")" ]; then
    bad "$name: extracted before refusing"
  else printf 'ok   %s\n' "$name"; fi
done
[ -e "$base/escaped" ] && bad "a member escaped the destination"
[ "$(cat "$base/outside")" = outside ] && [ "$(stat -f %l "$base/outside")" = 1 ] || bad "the outside file changed"

d=$base/dest-accept
if exec_ws_unpack "$base/accept-workspace.tar" "$d" 2>/dev/null &&
   [ "$(readlink "$d/src/b")" = a ] && [ "$(cat "$d/src/c")" = x ]; then
  printf 'ok   accept-workspace: internal links extract\n'
else bad "accept-workspace: a legitimate workspace was refused"; fi
case $(stat -f %Sp "$d/run.sh" 2>/dev/null) in *s*) bad "accept-workspace: setuid survived extraction" ;; esac

[ "$fail" = 0 ] && echo "Archive guard tests passed"
exit "$fail"
