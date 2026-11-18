# Integration notes (for Claude working in the iOS app)

You are wiring remote bank and store logos into the app. The logos live in two public GitHub
repos and are served for free through jsDelivr. Read this file first, then
`ios/RemoteLogos.swift`, which is a working reference implementation that typechecks against
the iOS 17 SDK in both Swift 5 and Swift 6 mode.

## 1. What the repos contain

| Repo | Manifest | Content |
| --- | --- | --- |
| [`s5956gpxwn-source/bank-logos`](https://github.com/s5956gpxwn-source/bank-logos) | `banks.json` | 25 banks and wallets (live, tag `v1`) |
| `s5956gpxwn-source/store-logos` | `stores.json` | stores (same layout, not created yet) |

Live URLs, for example:

- Manifest: `https://cdn.jsdelivr.net/gh/s5956gpxwn-source/bank-logos@main/banks.json`
- Image: `https://cdn.jsdelivr.net/gh/s5956gpxwn-source/bank-logos@v1/dark/png/alrajhi.png`

Both repos use the same layout, so the same code serves both:

```
light/png/{id}.png     light/svg/{id}.svg      full color, for light UI
dark/png/{id}.png      dark/svg/{id}.svg       full color, for dark UI
neutral/png/{id}.png   neutral/svg/{id}.svg    one white (#FFFFFF), dark backgrounds only
{manifest}.json
```

The neutral set is a white mono version, used **only on dark surfaces**, such as dark cards,
colored or photo headers, and dark-mode lists where brand colors would be noisy. Never show it
on a light background, because it would be invisible. It is a single color with alpha: secondary
parts are 45% white so two-color logos keep their shape. Shown as is it is white. Rendered as a
template image it can be tinted (`RemoteLogo(id:style: .neutral, tint: .white.opacity(0.8))`).

Manifest shape (extra keys such as `png_size`, `source` and `note` are informational):

```json
{
  "version": 1,
  "items": [
    { "id": "alrajhi", "name": "الراجحي",
      "color": "#231BFF", "color_dark": "#5D58FF",
      "secondary_color": null, "secondary_color_dark": null }
  ]
}
```

- `id` is the file name and a stable key. Ids are never renamed, only added. Map the app's
  own bank identifiers (enum, SMS sender names, and so on) to these ids in the app.
- `color` is the brand color for light UI. `color_dark` is the color the dark logo actually
  uses, so it may be `#FFFFFF`. For tinted backgrounds, use `color` at low opacity in both modes.
- Logos have transparent backgrounds. PNGs have a long side of 1200 px.
- Use the PNGs. iOS cannot decode SVG at runtime with public API: `UIImage(data:)` and
  `AsyncImage` do not support it, and Xcode supports SVG only inside asset catalogs at build
  time.

## 2. Hosting: public GitHub repo + jsDelivr

```
https://cdn.jsdelivr.net/gh/{owner}/{repo}@{ref}/{path}
```

This setup was checked against jsDelivr's README and with live response headers in November 2026:

| ref | CDN cache | `Cache-Control` sent to the device |
| --- | --- | --- |
| tag (`@v3`) or commit SHA | permanent | `public, max-age=31536000, s-maxage=31536000, immutable` |
| branch (`@main`) | 12 h | `public, max-age=604800, s-maxage=43200` |

PNG is served as `image/png` and SVG as `image/svg+xml`, with `access-control-allow-origin: *`.
The per-file limit is 20 MB and the per-package limit is 150 MB, so these repos are far below
both. The repo must stay **public**, because jsDelivr does not serve private repos.

Don't use `raw.githubusercontent.com` for images in production. It is not a CDN, it is
rate-limited, and it gives no versioned immutability.

### Versioning scheme (no app update needed to ship new logos)

- The **manifest** is read from `@main`. Because the branch response carries `max-age=7d`,
  always fetch it with `.reloadIgnoringLocalCacheData`. The CDN may still serve a copy up to 12 h
  old, which is fine for logos.
- **Images** are read from `@v{manifest.version}`. The URL changes whenever the version
  changes, so the device can cache images forever (`.returnCacheDataElseLoad`). Images then
  work offline, and a stale logo can never be served.

Release procedure in the logo repo: change the files, bump `version` in the manifest, commit,
tag `v{version}`, and push the branch and tag together so the manifest never points at a
missing tag:

```bash
git tag v2 && git push --atomic origin main v2
```

Optionally ask jsDelivr to refresh the manifest sooner:
`https://purge.jsdelivr.net/gh/s5956gpxwn-source/bank-logos@main/banks.json`. If purging is unavailable,
the CDN refreshes within 12 h anyway. Purging never applies to tag URLs, and tag URLs never
need it.

## 3. App implementation (see `ios/RemoteLogos.swift`)

- `LogoSource`: one value per repo (`.banks`, `.stores`). It builds the manifest and image URLs.
- `LogoStore` (`@MainActor`, `ObservableObject`): loads the last saved manifest from
  Application Support immediately, then refreshes it from the network. Call
  `await LogoStore.shared.refresh(.banks)` (and `.stores`) from the root view's `.task`, and
  optionally again when the app returns to the foreground.
- `LogoImageLoader` (actor): a dedicated `URLSession` with a 100 MB disk `URLCache` in Caches,
  an `NSCache` memory layer, de-duplication of in-flight requests, and **ImageIO downsampling**
  to `size × displayScale`. Without downsampling, each 1200 px PNG decodes to about 5.7 MB.
- `RemoteLogo(id:source:style:size:tint:)`: with `style: .brand` (the default) it reads
  `colorScheme` and requests the `light` or `dark` PNG. With `style: .neutral` it always requests
  `neutral` (white, so the caller must make sure the background is dark), and `tint` (optional)
  switches it to template rendering. The view reloads when the scheme, style or manifest version
  changes. Until the image arrives, or when the id is unknown, it shows a monogram circle tinted
  with `color` or `color_dark` (white for neutral).

Before you copy it in, adapt it to the project:

1. If the project already uses Kingfisher, Nuke or SDWebImage, keep `LogoSource` and
   `LogoStore` and use that library's loader with its downsampling processor instead of
   `LogoImageLoader`. Don't add a new dependency just for this.
2. If the deployment target is iOS 17 or later and the project uses `@Observable`, convert
   `LogoStore` to `@Observable`.
3. If the app already has a hex `Color` initializer, use it and drop `Color(logoHex:)`.
4. Keep the placeholder visually consistent with the existing bank and card UI.
5. Optional: ship a copy of the manifest in the app bundle as a first-launch fallback when
   there is no network.

## 4. Adding logos later (same rules for the stores repo)

Dark and neutral variants are generated, not drawn by hand. On a Mac, run
`zsh scripts/build.sh [manifest.json]`. The script applies these rules (see
`scripts/make_variants.py`):

- Dark:
  - A color with OKLCH lightness below 0.36 becomes white.
  - A color that already has at least 3:1 contrast on `#1C1C1E` is kept.
  - Any other color is lightened with its hue kept until it reaches 4:1 contrast.
  - Manual exceptions live in `scripts/dark-overrides.json`. The value `"lighten"` forces the
    lightening rule where white would apply; the owner preferred this for STC.
- Neutral:
  - Everything becomes white `#FFFFFF`, and the secondary-color parts get 45% opacity.
  - White parts become knockouts, and gradients become flat.
  - Exceptions live in `scripts/neutral-overrides.json`.

The script writes `dark/` and `neutral/` (PNGs are rendered by `scripts/svg2png.swift` through
AppKit) and stores `color_dark` and `neutral_color` in the manifest. For the stores repo, copy `scripts/` and keep the same
manifest schema (`version` plus `items`), so `RemoteLogo(id:source: .stores)` works unchanged.
