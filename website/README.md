# VectorLabel marketing website

A single, self-contained marketing page for VectorLabel — a standalone HTML5 document
with all styles, SVG icons, and CSS/SVG animations inline in [`index.html`](index.html).
There are **no external dependencies, fonts, or scripts**, so it works offline and can't
break from a dead CDN link.

**Live:** https://ryancoopster.github.io/VectorLabel/ (auto-deploys from this folder on
every push — see [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)).

## Preview locally

```bash
node website/serve.js      # serves at http://127.0.0.1:4599
```

(`serve.js` is a dev-only helper — it is not published to GitHub Pages.)

## Putting it on Squarespace — use the iframe embed

Add an **Embed** block (or a Code block) pointing at the live URL:

```html
<iframe src="https://ryancoopster.github.io/VectorLabel/"
        style="width:100%; height:100vh; border:0;" title="VectorLabel"></iframe>
```

The iframe fully **isolates** the page's CSS and JavaScript from the rest of your
Squarespace site.

> **Do not paste the raw `index.html` into a Squarespace Code Block.** This page uses a
> global CSS reset (`*`, `html`, `body`, and bare element selectors) by design; pasted
> inline, those rules leak out and restyle your entire Squarespace page. The iframe is
> the supported embed. The in-page nav also scrolls via JavaScript without changing the
> URL hash, so Squarespace can't hijack a click into a blank page.

## Customizing

- **Colors / accent:** edit the CSS variables in the `:root { … }` block near the
  top — `--accent` is the blue used throughout; `--ink`, `--bg`, `--bg-soft` set the
  neutrals.
- **Download links:** the buttons point at
  `https://github.com/ryancoopster/VectorLabel/releases`. Update them once you cut a
  release with an attached build.
- **Swap the animations for real footage:** the hero printer/label and the data-binding
  panel are pure CSS mockups. When you have screen recordings, drop a `<video autoplay
  muted loop playsinline>` or an animated GIF/`<img>` in place of the `.stage` and
  `.bind-visual` blocks — the surrounding layout already reserves the space.
