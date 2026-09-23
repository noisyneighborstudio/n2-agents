import { ImageResponse } from 'workers-og';

import bebas from './fonts/BebasNeue-Regular.ttf';
import mono from './fonts/SpaceMono-Regular.ttf';
import { card, DEFAULTS, PROFILES, clean } from './card.js';

const FONTS = [
  { name: 'Bebas Neue', data: bebas, weight: 400, style: 'normal' },
  { name: 'Space Mono', data: mono, weight: 400, style: 'normal' },
];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname !== '/og.png') return env.ASSETS.fetch(request);

    const cache = caches.default;
    const hit = await cache.match(request);
    if (hit) return hit;

    const q = url.searchParams;
    const html = card({
      label: clean(q.get('label'), DEFAULTS.label, 48),
      title: clean(q.get('t'), DEFAULTS.title, 78),
      text: clean(q.get('s'), DEFAULTS.text, 220),
      accent: PROFILES[(q.get('p') || '').toLowerCase()] || PROFILES.work,
    });

    const image = new ImageResponse(html, { width: 1200, height: 630, format: 'png', fonts: FONTS });

    /* Buffer before answering. Streaming the body straight through meant a
       failed render surfaced as an empty 200, which then got written to the
       cache and pinned for the whole s-maxage week. Verify the PNG signature
       and throw on anything else: a 500 lets the bot come back, an empty
       image it has already cached does not. */
    const bytes = new Uint8Array(await image.arrayBuffer());
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (bytes.length < 1024 || signature.some((b, i) => bytes[i] !== b)) {
      throw new Error(`og.png render returned ${bytes.length} bytes, not a PNG`);
    }

    const response = new Response(bytes, {
      headers: {
        'content-type': 'image/png',
        'content-length': String(bytes.length),
        'cache-control': 'public, max-age=86400, s-maxage=604800',
      },
    });

    ctx.waitUntil(cache.put(request, response.clone()));
    return response;
  },
};
