#!/usr/bin/env python3
"""Build silent 1080p demo clips for the n2-agents starter set.

Fixture: isolated HOME + fake vendor CLIs (mirrors scripts/test.sh), so no
real profile or login is touched. Captures REAL `./agents` output, renders
each transcript to a 1920x1080 PNG with PIL, encodes to silent MP4 with ffmpeg.
"""
import glob, os, subprocess, shutil, sys

ROOT = "/tmp/n2demo"
HOME = f"{ROOT}/home"
FAKE = f"{ROOT}/fake-bin"
FRAMES = f"{ROOT}/frames"
OUTDIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(OUTDIR))

# `agents list` also lists every /Applications/Claude-<Name>.app as a profile,
# and there is no override. Those are this machine's real profile names, so
# their rows are dropped from the capture; everything else is verbatim.
LOCAL_CLONES = {os.path.basename(a)[len("Claude-"):-len(".app")]
                for a in glob.glob("/Applications/Claude-*.app")}

CLIPS = [
    ("01-list", "agents list — profiles x labs", [["list"]]),
    ("02-vendors", "agents vendors — isolation table", [["vendors"]]),
    ("03-use-pin", "agents use — pin one lab", [["use", "Work", "--vendor", "codex"], ["active"], ["active", "--vendor", "codex"]]),
    ("04-best", "agents best — quota-aware routing", [["best", "--vendor", "codex"]]),
    ("05-sessions", "agents sessions — recent prompts", [["sessions", "Work"]]),
    ("06-run", "agents run — execute as profile", [["run", "Work", "--vendor", "codex"]]),
]

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def run_agents(args, extra_env=None, real_path=False):
    env = {"HOME": HOME, "PATH": "/usr/bin:/bin:/opt/homebrew/bin" if real_path else f"{FAKE}:/usr/bin:/bin",
           "XDG_CONFIG_HOME": f"{HOME}/.config",
           "N2_CODEX_USAGE_URL": f"file://{ROOT}/codex-usage.json"}
    if extra_env:
        env.update(extra_env)
    # The caller's own lab pins (e.g. CLAUDE_CONFIG_DIR) would leak into the
    # captured output, so only the fixture's environment goes in.
    base = {k: v for k, v in os.environ.items()
            if k not in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME", "CURSOR_CONFIG_DIR",
                         "XDG_CONFIG_HOME", "TBH_CREDENTIAL_BACKEND")}
    p = sh([f"{REPO}/agents"] + args, env={**base, **env})
    return (p.stdout or "") + (p.stderr or "")

def fixture():
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(f"{FAKE}", exist_ok=True)
    for v in ["claude", "codex", "grok", "cursor-agent", "opencode", "muse"]:
        with open(f"{FAKE}/{v}", "w") as f:
            f.write('#!/bin/sh\necho "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-} CODEX_HOME=${CODEX_HOME:-} GROK_HOME=${GROK_HOME:-} CURSOR_CONFIG_DIR=${CURSOR_CONFIG_DIR:-} XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-} TBH_CREDENTIAL_BACKEND=${TBH_CREDENTIAL_BACKEND:-}"\n')
        os.chmod(f"{FAKE}/{v}", 0o755)
    with open(f"{FAKE}/security", "w") as f:
        f.write("#!/bin/sh\nexit 44\n")
    os.chmod(f"{FAKE}/security", 0o755)
    os.makedirs(HOME, exist_ok=True)
    print(run_agents(["new", "Work", "--vendors", "claude,codex,grok", "--cli-only"])[-200:])
    print(run_agents(["new", "Personal", "--vendors", "claude,codex", "--cli-only"])[-200:])
    # Signed-in slots so `best` has quota to show.
    with open(f"{HOME}/.n2-agents/Work/claude/.claude.json", "w") as f:
        f.write('{"oauthAccount": {"emailAddress": "work@example.com"}}')
    with open(f"{HOME}/.n2-agents/Work/codex/auth.json", "w") as f:
        f.write('{"tokens": {"access_token": "t", "account_id": "a"}}')
    with open(f"{ROOT}/codex-usage.json", "w") as f:
        f.write('{"rate_limit": {"limit_reached": false, "primary_window": {"used_percent": 44, "limit_window_seconds": 604800, "reset_at": 1790411072}, "secondary_window": null}}')
    # One session per lab for `sessions`.
    os.makedirs(f"{HOME}/.n2-agents/Work/claude/projects/p", exist_ok=True)
    with open(f"{HOME}/.n2-agents/Work/claude/projects/p/c1.jsonl", "w") as f:
        f.write('{"type":"user","cwd":"/src/alpha","gitBranch":"main","message":{"role":"user","content":[{"type":"text","text":"fix the parser"}]}}\n')
    os.makedirs(f"{HOME}/.n2-agents/Work/codex/sessions/2026/01/01", exist_ok=True)
    with open(f"{HOME}/.n2-agents/Work/codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-x1.jsonl", "w") as f:
        f.write('{"type":"session_meta","payload":{"cwd":"/src/beta","source":"cli","git":{"branch":"release"}}}\n')
        f.write('{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ship the release"}]}}\n')
    with open(f"{HOME}/.n2-agents/Work/codex/session_index.jsonl", "w") as f:
        f.write('{"id":"x1","thread_name":"Ship it","updated_at":"2026-01-01T00:00:00Z"}\n')

def capture():
    os.makedirs(FRAMES, exist_ok=True)
    transcripts = {}
    for slug, title, cmds in CLIPS:
        lines = []
        for c in cmds:
            out = run_agents(c, real_path=(slug == "02-vendors")).strip()
            if c == ["list"]:
                out = "\n".join(l for l in out.split("\n")
                                if len(l.split()) < 2 or l.split()[1] not in LOCAL_CLONES)
            lines.append(f"$ agents {' '.join(c)}")
            lines.append(out if out else "(no output)")
            lines.append("")
        text = "\n".join(lines).strip()
        transcripts[slug] = (title, text)
        with open(f"{FRAMES}/{slug}.txt", "w") as f:
            f.write(text)
        print(f"--- {slug} ({len(text)} chars) ---")
        print(text[:600])
    return transcripts

BG = (21, 23, 24)
FG = (230, 230, 230)
GREEN = (120, 220, 120)
DIM = (140, 140, 140)
FONT = "/System/Library/Fonts/SFNSMono.ttf"

def render_png(slug, title, text):
    from PIL import Image, ImageDraw, ImageFont
    W, H = 1920, 1080
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    f_title = ImageFont.truetype(FONT, 40)
    d.rectangle([0, 0, W, 110], fill=(30, 32, 33))
    d.text((60, 30), title, font=f_title, fill=FG)
    d.text((60, H - 60), "n2-agents demo - isolated fixture, silent capture", font=ImageFont.truetype(FONT, 22), fill=DIM)
    body_lines = text.split("\n")[:30]
    size = 27
    while size > 16:
        f_try = ImageFont.truetype(FONT, size)
        if max((d.textlength(l, font=f_try) for l in body_lines), default=0) <= 1800:
            break
        size -= 2
    f_body = ImageFont.truetype(FONT, size)
    y = 150
    for raw in body_lines:
        line = raw[:200]
        fill = GREEN if line.startswith("$") else FG
        d.text((60, y), line or " ", font=f_body, fill=fill)
        y += 30
        if y > H - 100:
            break
    path = f"{FRAMES}/{slug}.png"
    img.save(path)
    return path

def encode(slug):
    png, mp4 = f"{FRAMES}/{slug}.png", f"{OUTDIR}/{slug}.mp4"
    p = sh(["ffmpeg", "-y", "-loop", "1", "-framerate", "30", "-i", png,
            "-t", "7", "-vf", "scale=1920:1080,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-an", mp4])
    if p.returncode != 0:
        print(p.stderr[-2000:])
        raise SystemExit(f"ffmpeg failed for {slug}")
    q = sh(["ffprobe", "-v", "error", "-show_entries", "format=duration,size",
            "-of", "default=nw=1", mp4])
    print(f"{slug}.mp4: {q.stdout.strip().replace(chr(10), ' ')}")

if __name__ == "__main__":
    os.makedirs(OUTDIR, exist_ok=True)
    fixture()
    transcripts = capture()
    for slug, (title, text) in transcripts.items():
        render_png(slug, title, text)
        encode(slug)
    print("OK:", sorted(os.listdir(OUTDIR)))
