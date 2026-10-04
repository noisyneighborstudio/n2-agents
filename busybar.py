#!/usr/bin/env python3
"""Lab health alerts on a BUSY Bar (busy.app), a 72x16 RGB LED desk display.

    busybar.py --root R status                    key<TAB>value lines
    busybar.py --root R on|off [--address A] [--token-stdin]
    busybar.py --root R alert KIND TITLE [--key K]
    busybar.py --root R clear KEY

The switch, address and secret live in R/busybar.json (0600). With the switch
off, alert and clear do nothing. A bar that can't be reached costs one request
timeout; the failure goes to R/busybar.log and the caller carries on.
"""
import argparse
import fcntl
import json
import math
import os
import re
import struct
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zlib

APP = 'n2agents'
USB_HOST = '10.0.4.20'
CLOUD_HOST = 'api.busy.app'
TIMEOUT = 3

# Each alert: the word on the card, its color (also the LED blink), and how
# long the card stays, in seconds. 0 stays until something replaces or clears it.
KINDS = {
    'half':      ('50% LEFT', '#2979FFFF', 60),
    'quarter':   ('25% LEFT', '#FFD600FF', 60),
    'low':       ('10% LEFT', '#FFAB00FF', 120),
    'out':       ('OUT', '#FF1744FF', 0),
    'signedout': ('SIGNED OUT', '#FF1744FF', 0),
    'back':      ('BACK', '#00C853FF', 60),
}
HELLO = ('CONNECTED', '#FFFFFFFF', 5)

# --- the N2 mark: the app icon's hub and six lab nodes, at 16x16 -------------

MARK = """\
................
.......TT.......
.......TT.......
.......ss.......
..RR...ss...PP..
..RRs..ss..sPP..
.....s.WW.s.....
......WWWW......
......WWWW......
.....s.WW.s.....
..BBs..ss..sOO..
..BB...ss...OO..
.......ss.......
.......GG.......
.......GG.......
................"""
PALETTE = {'.': (0, 0, 0), 'W': (255, 255, 255), 's': (90, 122, 128), 'T': (29, 233, 200),
           'R': (255, 97, 89), 'P': (138, 79, 208), 'B': (30, 136, 229), 'O': (255, 167, 38),
           'G': (25, 192, 138)}


def mark_png():
    rows = b''.join(b'\0' + bytes(c for ch in line for c in PALETTE[ch]) for line in MARK.splitlines())

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


# --- motion ------------------------------------------------------------------
#
# Element timeouts only resolve whole seconds, so motion is a list of draws
# sent on a schedule. Redrawing an id updates it in place, but an element added
# mid-sequence draws on top for a frame before z-order applies, so everything
# mounts hidden, in z-order, before anything moves.
#
# 1. Ignition: a hairline in the status color grows from the center.
# 2. Split: it parts into two edges that uncover the N2 mark.
# 3. Glint: the edges fade while a soft light sweeps across the mark.
# 4. Slide: the mark eases to the left edge, trailing two ghosts.
# 5. Punch: the alert word zooms in big, stepping through the device fonts.
# 6. Settle: it zooms down into the label slot while the title slides in.

W, H = 72, 16
LOGO = 'logo.png'
CONTENT_X = 17
CONTENT_W = W - CONTENT_X
FRAME_MS = 50
HIDDEN, BLACK = '#00000000', '#000000FF'
TRANSIENT = ['edge-l', 'edge-r', 'mask-l', 'mask-r', 'glint-a', 'glint-b', 'ghost-1', 'ghost-2']
# Smallest to largest, with measured glyph advance, cap offset and height.
# `normal` and `large` are left out: their thin weight flickers mid-zoom.
FONTS = [('tiny', 4.4, 1, 5), ('small', 4.6, 2, 5), ('bold', 6.75, 2, 7), ('extra_large', 8, 2, 10)]


def rnd(x):
    return int(math.floor(x + 0.5))


def ease_out(t):
    return 1 - (1 - t) ** 3


def ease_in_out(t):
    return 4 * t ** 3 if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def steps(n):
    return [(i + 1) / n for i in range(n)]


def lerp(a, b, t):
    return rnd(a + (b - a) * t)


def alpha(color, opacity):
    return color[:7] + '%02X' % rnd(max(0, min(1, opacity)) * 255)


def rect(id, x, width, color, z, y=0, height=H, fill='solid', colors=None):
    return {'id': id, 'type': 'rectangle', 'x': x, 'y': y, 'width': max(1, width), 'height': max(1, height),
            'fill': fill, 'fill_colors': colors or [color], 'border_width': 0, 'z_index': z}


def logo(id, x, opacity, z):
    return {'id': id, 'type': 'image', 'path': LOGO, 'x': x, 'y': 0, 'opacity': rnd(opacity * 100), 'z_index': z}


def text_width(font, text):
    return rnd(font[1] * len(text)) - 1


def label(card, font, x, y, opacity=1):
    return {'id': 'label', 'type': 'text', 'text': card['label'], 'font': font[0],
            'color': alpha(card['color'], opacity), 'align': 'top_left', 'x': x, 'y': y, 'z_index': 5}


def title(card, x, opacity=1):
    return {'id': 'title', 'type': 'text', 'text': card['title'], 'font': 'small',
            'color': alpha('#FFFFFFFF', opacity), 'align': 'bottom_left', 'x': x, 'y': 15,
            'width': CONTENT_W, 'scroll_rate': 1500, 'scroll_start_delay': 1500, 'z_index': 5}


def card_elements(card):
    """The settled card: mark at the left, status word over a scrolling title."""
    return [logo('logo', 0, 1, 4), label(card, FONTS[0], CONTENT_X, 0), title(card, CONTENT_X)]


def intro_frames(card):
    color = card['color']
    cx, mid, half = (W - 16) // 2, W // 2, 7
    frames = []

    def hold(n):
        frames.extend([] for _ in range(n))

    frames.append([logo('ghost-2', cx, 0, 2), logo('ghost-1', cx, 0, 3), logo('logo', cx, 0, 4),
                   label(card, FONTS[0], CONTENT_X, 0, 0), title(card, W, 0),
                   rect('mask-l', cx, 8, BLACK, 20), rect('mask-r', mid, 8, BLACK, 20),
                   rect('glint-a', 0, 1, HIDDEN, 25), rect('glint-b', 0, 1, HIDDEN, 25),
                   rect('edge-l', mid, 1, HIDDEN, 30), rect('edge-r', mid, 1, HIDDEN, 30)])
    # 1. Ignition.
    for i, t in enumerate(steps(4)):
        height = lerp(2, H, ease_out(t))
        frames.append(([logo('logo', cx, 1, 4)] if i == 0 else [])
                      + [rect('edge-l', mid, 1, color, 30, (H - height) // 2, height)])
    # 2. Split.
    for t in steps(7):
        spread = lerp(0, half, ease_out(t))
        left, right = mid - spread, mid + spread
        frames.append([logo('logo', cx, 1, 1), rect('mask-l', cx, left - cx, BLACK, 20),
                       rect('mask-r', right, cx + 16 - right, BLACK, 20),
                       rect('edge-l', left - 1, 1, color, 30), rect('edge-r', right, 1, color, 30)])
    # 3. Glint.
    for i, t in enumerate(steps(6)):
        x = lerp(cx - 2, cx + 16, ease_in_out(t))
        frames.append(([rect('mask-l', cx, 1, HIDDEN, 20), rect('mask-r', cx, 1, HIDDEN, 20)] if i == 0 else [])
                      + [rect('edge-l', mid - half - 1 - i, 1, alpha(color, 1 - t), 30),
                         rect('edge-r', mid + half + i, 1, alpha(color, 1 - t), 30),
                         rect('glint-a', x - 2, 2, HIDDEN, 25, fill='gradient_h', colors=['#FFFFFF00', '#FFFFFFB0']),
                         rect('glint-b', x, 2, HIDDEN, 25, fill='gradient_h', colors=['#FFFFFFB0', '#FFFFFF00'])])
    frames.append([rect('edge-l', 0, 1, HIDDEN, 30), rect('edge-r', 0, 1, HIDDEN, 30),
                   rect('glint-a', 0, 1, HIDDEN, 25), rect('glint-b', 0, 1, HIDDEN, 25)])
    hold(4)
    # 4. Slide.
    slide = [lerp(cx, 0, ease_in_out(t)) for t in steps(10)]
    for i, x in enumerate(slide):
        last = i == len(slide) - 1
        frames.append([logo('ghost-2', slide[i - 2] if i >= 2 else cx, 0 if last else 0.15, 2),
                       logo('ghost-1', slide[i - 1] if i >= 1 else cx, 0 if last else 0.35, 3),
                       logo('logo', x, 1, 4)])
    frames.append([logo('ghost-1', 0, 0, 3), logo('ghost-2', 0, 0, 2)])
    hold(2)
    # 5. Punch: the biggest font the word fits in beside the mark.
    peak = next((i for i in range(len(FONTS) - 1, 0, -1)
                 if text_width(FONTS[i], card['label']) <= CONTENT_W - 2), 0)

    def centered(font):
        return (CONTENT_X + rnd((CONTENT_W - text_width(font, card['label'])) / 2), rnd((H - font[3]) / 2) - font[2])
    zoom_in = [max(0, peak - 2), max(0, peak - 1), peak]
    for i, f in enumerate(zoom_in):
        x, y = centered(FONTS[f])
        frames.append([label(card, FONTS[f], x, y, (i + 1) / len(zoom_in))])
    hold(10)
    # 6. Settle.
    fx, fy = centered(FONTS[peak])
    for t in steps(max(peak + 1, 6)):
        e = ease_in_out(t)
        font = FONTS[peak - rnd(e * peak)]
        frames.append([label(card, font, lerp(fx, CONTENT_X, e), lerp(fy, 0, e))])
    for t in steps(8):
        frames.append([title(card, lerp(W, CONTENT_X, ease_out(t)))])
    return frames


# --- device ------------------------------------------------------------------

def endpoint(address, token):
    """The device serves /api; the cloud proxy serves the same API under /busybar."""
    raw = address.strip() or USB_HOST
    parsed = urllib.parse.urlsplit(raw if re.match(r'https?://', raw, re.I) else '//' + raw)
    host = parsed.hostname or raw
    cloud = host == CLOUD_HOST
    base = '%s://%s%s' % (parsed.scheme or ('https' if cloud else 'http'), parsed.netloc,
                          '/busybar' if cloud else '/api')
    headers = {} if not token else {'Authorization': 'Bearer ' + token} if cloud else {'X-API-Token': token}
    return {'base': base, 'headers': headers, 'host': host,
            'connection': 'cloud' if cloud else 'usb' if host == USB_HOST else 'wifi'}


def device_text(text):
    """The device fonts are bitmap ASCII."""
    text = unicodedata.normalize('NFKD', text)
    return re.sub(r'\s+', ' ', re.sub(r'[^\x20-\x7E]', '', text)).strip()


class Bar:
    def __init__(self, config):
        self.end = endpoint(config.get('address', ''), config.get('token', ''))

    def send(self, method, path, body=None, raw=None):
        data = raw if raw is not None else None if body is None else json.dumps(body).encode()
        headers = dict(self.end['headers'])
        if data is not None:
            headers['Content-Type'] = 'application/octet-stream' if raw is not None else 'application/json'
        request = urllib.request.Request(self.end['base'] + path, data=data, method=method, headers=headers)
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, response.read()

    def clear(self, ids=None):
        self.send('DELETE', '/display/draw', {'application_name': APP, **({'element_ids': ids} if ids else {})})

    def draw(self, card, elements, led=None):
        body = {'application_name': APP,
                'elements': [{'display': 'front', 'timeout': card['timeout'], **e} for e in elements]}
        if led:
            body['led_notification_color'] = led
        self.send('POST', '/display/draw', body)

    def play(self, card):
        """The intro on its schedule, then the settled card with its LED blink."""
        self.clear()  # draws add to what is on screen
        self.send('POST', '/assets/upload?' + urllib.parse.urlencode({'application_name': APP, 'file': LOGO}),
                  raw=mark_png())
        start = time.monotonic()
        for i, elements in enumerate(intro_frames(card)):
            wait = start + i * FRAME_MS / 1000 - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            if elements:
                self.draw(card, elements)
        self.clear(TRANSIENT)
        self.draw(card, card_elements(card), led=card['color'])

    def probe(self):
        try:
            status, body = self.send('GET', '/version')
            return 'connected', json.loads(body or b'{}').get('api_semver', '')
        except urllib.error.HTTPError as e:
            return ('unauthorized' if e.code in (401, 403) else 'unreachable'), ''
        except (OSError, ValueError):
            return 'unreachable', ''


def make_card(kind, title_text):
    word, color, timeout = HELLO if kind == 'hello' else KINDS[kind]
    return {'label': word, 'color': color, 'timeout': timeout, 'title': device_text(title_text)}


# --- state -------------------------------------------------------------------

class Store:
    def __init__(self, root):
        self.root = root
        self.config_path = os.path.join(root, 'busybar.json')
        # The persistent card on screen, so only its own resolution clears it.
        self.state_path = os.path.join(root, 'busybar.state')

    def config(self):
        try:
            with open(self.config_path) as f:
                value = json.load(f)
        except (OSError, ValueError):
            value = {}
        return {'enabled': value.get('enabled') is True, 'address': str(value.get('address', '')),
                'token': str(value.get('token', ''))}

    def save(self, config):
        os.makedirs(self.root, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=self.root)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, 'w') as f:
                json.dump(config, f)
            os.replace(temporary, self.config_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def showing(self):
        try:
            with open(self.state_path) as f:
                return f.read().strip()
        except OSError:
            return ''

    def show(self, key):
        if key:
            with open(self.state_path, 'w') as f:
                f.write(key)
        elif os.path.exists(self.state_path):
            os.unlink(self.state_path)

    def lock(self):
        """One sequence at a time, or two alerts would interleave their frames."""
        os.makedirs(self.root, exist_ok=True)
        handle = open(os.path.join(self.root, 'busybar.lock'), 'w')
        fcntl.flock(handle, fcntl.LOCK_EX)
        return handle

    def log(self, message):
        with open(os.path.join(self.root, 'busybar.log'), 'a') as f:
            f.write('%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), message))


def attempt(store, what, action):
    """Runs one device sequence; a failure is logged, never raised."""
    try:
        action()
        return True
    except (OSError, ValueError) as e:
        store.log('%s failed: %s' % (what, e))
        return False


def status_lines(store):
    config = store.config()
    bar = Bar(config)
    state, version = bar.probe()
    return ['enabled\t' + ('on' if config['enabled'] else 'off'), 'address\t' + config['address'],
            'token\t' + ('set' if config['token'] else 'none'), 'connection\t' + bar.end['connection'],
            'host\t' + bar.end['host'], 'state\t' + state, 'api\t' + version]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('status')
    for name in ('on', 'off'):
        switch = sub.add_parser(name)
        switch.add_argument('--address')
        switch.add_argument('--token-stdin', action='store_true', help='read the password or token from stdin')
    alert = sub.add_parser('alert')
    alert.add_argument('kind', choices=sorted(KINDS))
    alert.add_argument('title')
    alert.add_argument('--key', default='')
    clear = sub.add_parser('clear')
    clear.add_argument('key')
    args = parser.parse_args(argv)
    store = Store(args.root)

    if args.command == 'status':
        print('\n'.join(status_lines(store)))
        return 0
    if args.command in ('on', 'off'):
        config = store.config()
        config['enabled'] = args.command == 'on'
        if args.address is not None:
            config['address'] = args.address.strip()
        if args.token_stdin:
            config['token'] = sys.stdin.readline().strip()
        store.save(config)
        with store.lock():
            bar = Bar(config)
            store.show('')
            if config['enabled']:
                attempt(store, 'hello', lambda: bar.play(make_card('hello', 'N2 Agents')))
            else:
                attempt(store, 'clear', bar.clear)
        print('\n'.join(status_lines(store)))
        return 0

    config = store.config()
    if not config['enabled']:
        return 0
    bar = Bar(config)
    with store.lock():
        if args.command == 'alert':
            card = make_card(args.kind, args.title)
            if attempt(store, 'alert %s' % args.kind, lambda: bar.play(card)):
                store.show(args.key if card['timeout'] == 0 else '')
        elif store.showing() == args.key and attempt(store, 'clear', bar.clear):
            store.show('')
    return 0


if __name__ == '__main__':
    sys.exit(main())
