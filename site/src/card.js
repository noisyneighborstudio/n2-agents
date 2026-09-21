/* The unfurl card's markup. No Worker or font imports, so it can be
   rendered and inspected from plain node. */

const CHARCOAL = '#0D0D0D';
const BONE = '#EDEDE6';
const CONCRETE = '#7A7A74';

/* The six labs, in the order the hub mark draws them: top, then clockwise.
   Same hex values as the favicon and the node graph in index.html. */
const LABS = [
  ['Claude', '#18E4CC'],
  ['Codex', '#7848C0'],
  ['Grok', '#F09C24'],
  ['Gemini', '#0CB490'],
  ['Cursor', '#1884E4'],
  ['opencode', '#FC6054'],
];

/* Profile accents, matching the switcher pills on the page. */
const PROFILES = { work: '#FFEA00', personal: '#EDEDE6', client: '#FF3D00' };

const DEFAULTS = {
  label: 'Six tenants, one lease',
  title: 'One identity.|Every lab.',
  text: 'Each profile holds its own Claude, Codex, Grok, Gemini, Cursor and opencode login.',
};

/* satori's HTML parser decodes no entities at all: "&amp;" renders as the
   literal five characters. So escaping is worse than useless here. Strip the
   two characters that can open a tag and leave the rest verbatim. Nothing
   user-supplied is ever interpolated into an attribute, only into text. */
const safe = (s) => s.replace(/[<>]/g, '');

/* Bots follow whatever URL sits in the meta tag, so treat every param as
   hostile: drop control characters, cap the length, strip tag characters. */
const clean = (raw, fallback, max) => {
  const trimmed = (raw ?? '').replace(/[\u0000-\u001F\u007F]/g, ' ').trim();
  const value = trimmed || fallback;
  return safe(value.length > max ? value.slice(0, max - 1).trimEnd() + '\u2026' : value);
};

/* satori measures wrapped text unreliably: a headline that breaks onto a
   second line keeps its one-line height and collides with whatever follows.
   So the lines get decided here and each is emitted as its own row.
   `|` is an explicit break, mirroring the <br> in the page's own h1. */
function lines(title, perLine = 26) {
  if (title.includes('|')) return title.split('|').map((l) => l.trim()).filter(Boolean).slice(0, 3);
  const out = [];
  for (const word of title.split(/\s+/)) {
    const i = out.length - 1;
    if (i >= 0 && (out[i] + ' ' + word).length <= perLine) out[i] += ' ' + word;
    else out.push(word);
  }
  return out.slice(0, 3);
}

/* 6 dots on a hexagon plus a filled core, the same mark as the favicon.
   Absolute positions beat transforms: satori's rotate support is patchy. */
function hub(accent) {
  const BOX = 104, R = 40, C = BOX / 2, D = 15;
  const dots = LABS.map(([, color], i) => {
    const a = ((-90 + i * 60) * Math.PI) / 180;
    const x = C + R * Math.cos(a) - D / 2;
    const y = C + R * Math.sin(a) - D / 2;
    return `<div style="position:absolute;left:${x.toFixed(1)}px;top:${y.toFixed(1)}px;width:${D}px;height:${D}px;border-radius:${D}px;background:${color};"></div>`;
  }).join('');
  const core = D + 5;
  const ring = R * 2;
  return `<div style="position:relative;width:${BOX}px;height:${BOX}px;">
    <div style="position:absolute;left:${C - ring / 2}px;top:${C - ring / 2}px;width:${ring}px;height:${ring}px;border-radius:${ring}px;border:1px solid rgba(237,237,230,0.16);"></div>
    ${dots}
    <div style="position:absolute;left:${C - core / 2}px;top:${C - core / 2}px;width:${core}px;height:${core}px;border-radius:${core}px;background:${accent};"></div>
  </div>`;
}

/* Hazard strip. Discrete blocks because satori has no
   repeating-linear-gradient, and a plain bar loses the reference. */
function tape(accent) {
  const blocks = Array.from({ length: 48 }, (_, i) =>
    `<div style="width:25px;height:10px;background:${i % 2 ? CHARCOAL : accent};"></div>`).join('');
  return `<div style="width:1200px;height:10px;">${blocks}</div>`;
}

/* satori rejects any div without an explicit display, even a leaf holding
   only text, and counts whitespace between tags as a child node. Normalising
   once here beats repeating display:flex across thirty style attributes. */
const forSatori = (html) =>
  html.replace(/>\s+</g, '><').replace(/style="(?![^"]*display:)/g, 'style="display:flex;');

function card({ label, title, text, accent }) {
  const rows = lines(title);
  const longest = rows.reduce((n, l) => Math.max(n, l.length), 1);
  const size = Math.min(94, Math.round((94 * 24) / Math.max(longest, 24)));

  const heading = rows.map((l) =>
    `<div style="font-family:Bebas Neue;font-size:${size}px;line-height:1.06;letter-spacing:2px;color:${BONE};">${l}</div>`).join('');

  const chips = LABS.map(([name, color]) =>
    `<div style="align-items:center;margin-right:24px;">
       <div style="width:10px;height:10px;border-radius:10px;background:${color};margin-right:8px;"></div>
       <div style="font-family:Space Mono;font-size:18px;color:${CONCRETE};">${name}</div>
     </div>`).join('');

  return forSatori(`<div style="flex-direction:column;width:1200px;height:630px;background:${CHARCOAL};">
    ${tape(accent)}
    <div style="flex-direction:column;flex:1;padding:50px 72px 44px 72px;">

      <div style="align-items:flex-start;justify-content:space-between;width:100%;">
        <div style="align-items:center;padding-top:16px;">
          <div style="width:12px;height:12px;border-radius:12px;background:${accent};margin-right:14px;"></div>
          <div style="font-family:Space Mono;font-size:20px;letter-spacing:3px;color:${CONCRETE};">${label.toUpperCase()}</div>
        </div>
        ${hub(accent)}
      </div>

      <div style="flex-direction:column;margin-top:10px;">${heading}</div>

      <div style="font-family:Space Mono;font-size:22px;line-height:1.5;color:#9C9B94;margin-top:24px;width:1010px;">${text}</div>

      <div style="flex:1;"></div>

      <div style="align-items:center;">${chips}</div>

      <div style="width:100%;height:1px;background:rgba(237,237,230,0.12);margin-top:26px;"></div>

      <div style="align-items:center;justify-content:space-between;width:100%;margin-top:20px;font-family:Space Mono;font-size:18px;letter-spacing:2px;">
        <div style="color:${BONE};">AGENTS.NOISYNEIGHBOR.STUDIO</div>
        <div style="color:${CONCRETE};">MIT · MACOS MENU BAR + CLI</div>
      </div>

    </div>
  </div>`);
}

export { card, DEFAULTS, PROFILES, LABS, safe, clean, lines };
