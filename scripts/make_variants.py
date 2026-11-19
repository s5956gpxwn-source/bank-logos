#!/usr/bin/env python3
"""Generate dark/svg and neutral/svg from light/svg, and write the dark colors into the manifest.

Usage:  python3 scripts/make_variants.py [manifest.json]      (run from the repo root)

DARK rules (same for every logo, so new ones stay consistent):
  1. A color with OKLCH lightness < 0.36 ("dark ink": navy, black, deep purple) becomes white.
  2. A color that already has >= 3:1 contrast on #1C1C1E is kept as is.
  3. Anything in between is lightened in OKLCH (hue kept) until it reaches 4:1 on #1C1C1E.
  4. scripts/dark-overrides.json wins: {"<id>": {"#OLD": "#NEW" | "lighten" | "none"}}
     ("lighten" = apply rule 3 even where rule 1 would give white;
      "none" = drop that fill so the shape becomes a see-through cutout).

NEUTRAL rules (one white, for dark backgrounds only; can be tinted as a template image):
  - Every color becomes NEUTRAL. Parts in the secondary color (closest to `secondary_color`)
    get SECONDARY_OPACITY so two-color logos keep their inner separation.
  - White parts become transparent (they are knockouts). Gradients become flat.
  - scripts/neutral-overrides.json sets opacities per color: {"<id>": {"#HEX": 0.45}}.

Shapes with no fill (SVG default = black) get an inherited fill on the root <svg>.
"""
import json, math, os, re, sys

MANIFEST = sys.argv[1] if len(sys.argv) > 1 else 'banks.json'
BG = '#1C1C1E'
WHITE_BELOW_L, KEEP_CONTRAST, TARGET = 0.36, 3.0, 4.0
NEUTRAL, SECONDARY_OPACITY = '#FFFFFF', 0.45
H = r'(#[0-9a-fA-F]{6}|#[0-9a-fA-F]{3})(?![0-9a-fA-F])'
HEX = re.compile(H)


def s2l(c):
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def l2s(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def hex2rgb(h):
    h = h.lstrip('#')
    h = ''.join(x * 2 for x in h) if len(h) == 3 else h
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def norm(h):
    return '#%02X%02X%02X' % tuple(hex2rgb(h))


def dist(a, b):
    return math.dist(hex2rgb(a), hex2rgb(b))


def lum(h):
    r, g, b = [s2l(x) for x in hex2rgb(h)]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True)
    return (la + 0.05) / (lb + 0.05)


def to_oklch(h):
    r, g, b = [s2l(x) for x in hex2rgb(h)]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = [math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s)]
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(A, B), math.atan2(B, A)


def from_oklch(L, C, Hh):
    A, B = C * math.cos(Hh), C * math.sin(Hh)
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return [l2s(x) for x in (r, g, b)]


def oklch_hex(L, C, Hh):
    while C > 0 and not all(-1e-4 <= x <= 1 + 1e-4 for x in from_oklch(L, C, Hh)):
        C -= 0.002
    return '#%02X%02X%02X' % tuple(max(0, min(255, round(x * 255))) for x in from_oklch(L, max(C, 0), Hh))


def lighten(h):
    L, C, Hh = to_oklch(h)
    while L < 1:
        L += 0.004
        c = oklch_hex(L, C, Hh)
        if contrast(c, BG) >= TARGET:
            return c
    return '#FFFFFF'


def to_dark(h):
    h = norm(h)
    if to_oklch(h)[0] < WHITE_BELOW_L:
        return '#FFFFFF'
    if contrast(h, BG) >= KEEP_CONTRAST:
        return h
    return lighten(h)


def add_root_fill(svg, color):
    m = re.search(r'<svg\b[^>]*>', svg)
    if m and not re.search(r'\sfill\s*=', m.group(0)):
        svg = svg[:m.start()] + '<svg fill="%s"' % color + svg[m.start() + 4:]
    return svg


def make_dark(svg, item, ov):
    mapping = {}

    def pick(old):
        old = norm(old)
        if old not in mapping:
            o = ov.get(old)
            mapping[old] = (lighten(old) if o == 'LIGHTEN' else 'none' if o == 'NONE'
                            else (o or to_dark(old)))
        return mapping[old]

    dark = add_root_fill(HEX.sub(lambda m: pick(m.group(0)), svg), pick('#000000'))
    item['color_dark'] = pick(item['color'])
    if item.get('secondary_color'):
        item['secondary_color_dark'] = pick(item['secondary_color'])
    return dark, {k: v for k, v in mapping.items() if k != v and k != '#000000'}


def make_neutral(svg, item, ov):
    primary, secondary = item['color'], item.get('secondary_color')

    def opacity(c):
        c = norm(c)
        if c in ov:
            return float(ov[c])
        if secondary and dist(c, secondary) < dist(c, primary):
            return SECONDARY_OPACITY
        return 1.0

    def attr(m):                       # fill="#hex"  /  stroke="#hex"
        prop, c = m.group(1), norm(m.group(2))
        if c == '#FFFFFF':
            return f'{prop}="none"'
        a = opacity(c)
        return f'{prop}="{NEUTRAL}"' + (f' {prop}-opacity="{a:g}"' if a < 1 else '')

    def css(m):                        # fill: #hex  (inside <style> or style="")
        prop, c = m.group(1), norm(m.group(2))
        if c == '#FFFFFF':
            return f'{prop}: none'
        a = opacity(c)
        return f'{prop}: {NEUTRAL}' + (f'; {prop}-opacity: {a:g}' if a < 1 else '')

    out = re.sub(r'\b(fill|stroke)="' + H + '"', attr, svg)
    out = re.sub(r'\b(fill|stroke)\s*:\s*' + H, css, out)
    out = HEX.sub(NEUTRAL, out)        # gradient stops and anything left: flat neutral
    return add_root_fill(out, NEUTRAL)


def load(path):
    return json.load(open(path, encoding='utf-8')) if os.path.exists(path) else {}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    dark_ov = load(os.path.join(here, 'dark-overrides.json'))
    neutral_ov = load(os.path.join(here, 'neutral-overrides.json'))
    manifest = json.load(open(MANIFEST, encoding='utf-8'))
    manifest['neutral_color'] = NEUTRAL
    for d in ('dark/svg', 'neutral/svg'):
        os.makedirs(d, exist_ok=True)
    for item in manifest['items']:
        iid = item['id']
        svg = open(f'light/svg/{iid}.svg', encoding='utf-8').read()
        dov = {norm(k): (v.upper() if v.lower() in ('lighten', 'none') else norm(v))
               for k, v in dark_ov.get(iid, {}).items()}
        nov = {norm(k): v for k, v in neutral_ov.get(iid, {}).items()}
        dark, changed = make_dark(svg, item, dov)
        open(f'dark/svg/{iid}.svg', 'w', encoding='utf-8').write(dark)
        open(f'neutral/svg/{iid}.svg', 'w', encoding='utf-8').write(make_neutral(svg, item, nov))
        print(f'{iid:14}', ' '.join(f'{k}->{v}' for k, v in changed.items()) or '-')

    order = ['id', 'name', 'color', 'color_dark', 'secondary_color', 'secondary_color_dark']
    manifest['items'] = [{**{k: it[k] for k in order if k in it}, **it} for it in manifest['items']]
    with open(MANIFEST, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write('\n')


if __name__ == '__main__':
    main()
