# agents.noisyneighbor.studio

The N2 Agents marketing site. Static assets on Cloudflare Workers, plus one
Worker route that renders the link-unfurl card.

    public/index.html    the page (self-contained: inline CSS + JS)
    public/404.html      wrong door
    src/index.js         Worker: /og.png, everything else falls through to assets
    src/card.js          the unfurl card's markup
    src/fonts/           Bebas Neue + Space Mono, OFL, bundled for satori
    wrangler.jsonc       Worker + assets + custom domain

The page itself is still one file with no framework. There is no separate build
step: `wrangler deploy` bundles the Worker on its way up.

## Deploy

Merging to `main` deploys, whenever the merge touches `site/`. The workflow is
`.github/workflows/deploy-site.yml`: it builds, deploys, then checks that the
live page and `/og.png` both answer and that the card really is a 1200x630 PNG.
Pull requests run the build only, so a broken Worker is caught before merge
rather than after.

That needs one repository secret, `CLOUDFLARE_API_TOKEN`, with Account /
Workers Scripts: Edit. Without it the deploy stops with that message instead of
failing somewhere confusing.

CI ships code only (`versions upload` then `versions deploy`), never triggers,
so it doesn't need zone permissions. If you change `routes` in `wrangler.jsonc`,
apply them once by hand with a login that can edit the zone:

    npx wrangler triggers deploy

To push a build by hand:

    cd site
    npx wrangler deploy

`wrangler.jsonc` pins `account_id`, because the login sees more than one
account and wrangler stops to ask otherwise. It also declares
`agents.noisyneighbor.studio` as a `custom_domain`, so the first deploy created
the DNS record and the certificate in the same Cloudflare zone that already
serves noisyneighbor.studio. Later deploys just replace the assets.

## The unfurl card

`/og.png` renders a 1200x630 PNG at request time with satori + resvg, so the
card is generated rather than checked in. Open it in a browser to see changes.

    /og.png                              the homepage card
    /og.png?t=Stop switching|by hand     title, `|` forces a line break
    /og.png?s=...                        the body line
    /og.png?label=06 · Move in           the kicker above the title
    /og.png?p=work|personal|client       accent colour, matching the profile pills

Every param is capped and stripped before it reaches the renderer. Unknown `p`
values fall back to Work yellow.

`index.html` and `404.html` point `og:image` at this route with a `?v=1` on the
end. **Bump that `v` whenever the card design changes.** Slack, X and iMessage
cache unfurls by URL for days, and without a new URL they keep serving the old
picture.

Three satori behaviours are worth knowing before editing `card.js`, because each
one fails quietly:

- Every `<div>` needs an explicit `display`, including a leaf that only holds
  text. Whitespace between tags counts as a child node too. `forSatori()`
  normalises both, which is why the markup can stay indented.
- No HTML entities are decoded. `&amp;` renders as the literal five characters,
  so text is sanitised by stripping `<` and `>` rather than by escaping.
- Wrapped text keeps its single-line height and collides with whatever follows,
  so `lines()` decides the line breaks and emits each as its own row.

## Editing

The page is deliberately one file. It's built on the Noisy Neighbor design system.
The tokens at the top of `index.html` are lifted from noisyneighbor.studio/css/nn.css,
so changes there should be mirrored here.

One thing to watch: every `animation:` name must have a matching `@keyframes`.
CSS fails silently otherwise. The animation never runs.

    grep -o 'animation:[a-z0-9-]*' public/index.html | sed 's/animation://' | sort -u
    grep -o '@keyframes [a-z0-9-]*' public/index.html | sed 's/@keyframes //' | sort -u
