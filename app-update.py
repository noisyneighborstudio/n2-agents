#!/usr/bin/python3
"""Install the newest N2 Agents build from the app's own update feed.

Reads the same Sparkle appcast the app does, so the installed channel is kept.
A download replaces nothing unless its code signature verifies and it carries
the installed app's bundle id and signing team.
"""
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def team(app):
    result = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True)
    for line in result.stderr.splitlines():
        if line.startswith('TeamIdentifier='):
            return line.split('=', 1)[1]
    return None


def newest(feed):
    with urllib.request.urlopen(feed, timeout=30) as response:
        channel = ET.fromstring(response.read()).find('channel')
    items = []
    for item in channel.findall('item') if channel is not None else []:
        enclosure = item.find('enclosure')
        if enclosure is None:
            continue
        build = enclosure.get(SPARKLE + 'version', '')
        if build.isdigit():
            items.append((int(build), enclosure.get(SPARKLE + 'shortVersionString', build),
                          enclosure.get('url'), int(enclosure.get('length') or 0)))
    if not items:
        raise ValueError('the update feed lists no builds')
    return max(items)


def running(app):
    # ps reports the path a process was started with; compare resolved paths so
    # a symlinked folder (/var -> /private/var, a moved home) still matches.
    executable = os.path.realpath(app / 'Contents/MacOS') + '/'
    listing = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True).stdout
    return [int(pid) for pid, _, command in (line.strip().partition(' ') for line in listing.splitlines())
            if os.path.realpath(command.strip()).startswith(executable)]


def quit_app(pids):
    queue = select.kqueue()
    watched = []
    for pid in pids:
        try:
            queue.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
            os.kill(pid, signal.SIGTERM)
            watched.append(pid)
        except (ProcessLookupError, OSError):
            continue
    remaining = set(watched)
    while remaining:
        events = queue.control(None, len(remaining), 30)
        if not events:
            raise RuntimeError('N2 Agents did not quit; quit it and run agents update again')
        remaining -= {event.ident for event in events}


def main(app, feed, check_only):
    app = Path(app)
    current = info(app)
    installed = int(current.get('CFBundleVersion', '0') or 0)
    build, version, url, length = newest(feed)
    if build <= installed:
        print(f"N2 Agents {current.get('CFBundleShortVersionString', installed)} is up to date.")
        return 0
    if check_only:
        print(f"Update available: {version} (installed {current.get('CFBundleShortVersionString', installed)}).")
        return 0
    with tempfile.TemporaryDirectory(prefix='n2-update-', dir=app.parent) as work:
        work = Path(work)
        archive = work / 'update.zip'
        with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as out:
            shutil.copyfileobj(response, out)
        if length and archive.stat().st_size != length:
            raise ValueError('the download is not the size the feed lists')
        subprocess.run(['ditto', '-x', '-k', str(archive), str(work / 'unpacked')], check=True)
        candidates = list((work / 'unpacked').glob('*.app'))
        if len(candidates) != 1:
            raise ValueError('the download does not hold exactly one app')
        new = candidates[0]
        if subprocess.run(['codesign', '--verify', '--deep', '--strict', str(new)], capture_output=True).returncode:
            raise ValueError('the download is not validly signed')
        if info(new).get('CFBundleIdentifier') != current.get('CFBundleIdentifier'):
            raise ValueError('the download is a different app')
        if team(new) != team(app):
            raise ValueError('the download is signed by a different team')
        if int(info(new).get('CFBundleVersion', '0') or 0) != build:
            raise ValueError('the download is not the build the feed lists')
        was_running = running(app)
        quit_app(was_running)
        old = work / 'previous.app'
        os.rename(app, old)
        try:
            os.rename(new, app)
        except OSError:
            os.rename(old, app)
            raise
    print(f'Installed N2 Agents {version}.')
    if was_running and subprocess.run(['open', str(app)], capture_output=True).returncode:
        print('agents: installed, but could not reopen N2 Agents; open it yourself.', file=sys.stderr)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3:] == ['--check']))
    except (ValueError, RuntimeError, OSError, ET.ParseError, subprocess.SubprocessError, KeyError) as error:
        print(f'agents: update refused: {error}', file=sys.stderr)
        sys.exit(1)
