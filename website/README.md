# VectorLabel marketing website

A single, self-contained marketing page for VectorLabel. Everything — styles, SVG
icons, and CSS/SVG animations — is inline in [`index.html`](index.html). There are
**no external dependencies, fonts, or scripts**, so it works offline and can't break
from a dead CDN link.

## Preview locally

```bash
node website/serve.js      # serves at http://127.0.0.1:4599
```

(`serve.js` is a dev-only helper — it is not part of the page.)

## Putting it on Squarespace

Two easy options:

### Option A — Code Block (simplest, needs a Business plan or higher)
1. Edit the page → add a **Code** block.
2. Open `index.html`, copy **everything**, and paste it into the Code block.
3. Turn **off** "Display Source" so it renders instead of showing the code.

> The in-page nav links scroll via JavaScript (they never change the URL hash), so
> Squarespace won't hijack a click into a blank page load — that's the fix for the
> "nav buttons go to a blank page" problem. If the top nav overlaps Squarespace's own
> header, either hide the site header on that page, or delete the `<header class="nav">`
> block and use Squarespace's navigation instead.

### Option B — Host the file + iframe it (works on any plan)
1. Push this `website/` folder to **GitHub Pages** (Settings → Pages → deploy from
   the repo). You'll get a URL like `https://ryancoopster.github.io/VectorLabel/`.
2. On Squarespace, add an **Embed** block and point it at that URL, or paste an
   `<iframe src="…">` into a Code block.

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
