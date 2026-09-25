#!/usr/bin/env python3
"""Pack a workspace, materializing linked Git metadata without editing the source."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def git(path, *args, input=None, optional=False):
    result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-C', str(path), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode and not optional:
        raise ValueError('could not materialize Git workspace')
    return result.stdout if result.returncode == 0 else None


def pack(source, output):
    source = Path(source).resolve()
    output = Path(output).absolute()
    if not source.is_dir():
        raise ValueError('workspace is not a directory')
    if not (source / '.git').is_file():
        subprocess.run(['tar', '-cf', str(output), '-C', str(source), '.'], check=True)
        return
    with tempfile.TemporaryDirectory(prefix='n2-workspace-') as temporary:
        temporary = Path(temporary)
        bundle = temporary / 'repository.bundle'
        stage = temporary / 'workspace'
        head = git(source, 'rev-parse', 'HEAD').decode().strip()
        branch = git(source, 'symbolic-ref', '-q', 'HEAD', optional=True)
        patch = git(source, 'diff', '--no-ext-diff', '--no-textconv', '--cached', '--binary', '--full-index', 'HEAD')
        git(source, 'bundle', 'create', str(bundle), '--all', 'HEAD')
        subprocess.run(['git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', 'clone', '--no-checkout',
                        str(bundle), str(stage)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if branch:
            git(stage, 'symbolic-ref', 'HEAD', branch.decode().strip())
            git(stage, 'update-ref', 'HEAD', head)
        else:
            git(stage, 'update-ref', '--no-deref', 'HEAD', head)
        git(stage, 'read-tree', head)
        if patch:
            git(stage, 'apply', '--cached', '--binary', '--whitespace=nowarn', '-', input=patch)
        # The clone has no checked-out files. Copy the exact dirty tree without
        # the source's machine-specific .git pointer. Deletions stay deleted.
        for entry in source.iterdir():
            if entry.name == '.git':
                continue
            dest = stage / entry.name
            if entry.is_symlink():
                dest.symlink_to(os.readlink(entry))
            elif entry.is_dir():
                shutil.copytree(entry, dest, symlinks=True)
            else:
                shutil.copy2(entry, dest)
        # Do not leave a remote pointing into the temporary bundle directory.
        origin = git(source, 'remote', 'get-url', 'origin', optional=True)
        if origin:
            git(stage, 'remote', 'set-url', 'origin', origin.decode().strip())
        else:
            git(stage, 'remote', 'remove', 'origin')
        subprocess.run(['tar', '-cf', str(output), '-C', str(stage), '.'], check=True)


if __name__ == '__main__':
    try:
        pack(sys.argv[1], sys.argv[2])
    except (ValueError, OSError, subprocess.SubprocessError, IndexError):
        print('agents: could not pack a self-contained workspace', file=sys.stderr)
        sys.exit(1)
