#!/bin/zsh
# Regenerates dark/ and neutral/ (svg + png), and any missing light/png, from light/svg.
# Run from anywhere on macOS:  zsh scripts/build.sh [manifest.json]
set -e
cd "$(dirname "$0")/.."
MANIFEST="${1:-banks.json}"
BIN="${TMPDIR:-/tmp}/svg2png-logos"
[[ -x "$BIN" && "$BIN" -nt scripts/svg2png.swift ]] || swiftc -O scripts/svg2png.swift -o "$BIN"
python3 scripts/make_variants.py "$MANIFEST"
mkdir -p light/png dark/png neutral/png
for f in light/svg/*.svg; do
  id="${f:t:r}"
  [[ -f "light/png/$id.png" ]] || "$BIN" "$f" "light/png/$id.png" 1200 >/dev/null
  "$BIN" "dark/svg/$id.svg" "dark/png/$id.png" 1200 >/dev/null
  "$BIN" "neutral/svg/$id.svg" "neutral/png/$id.png" 1200 >/dev/null
done
echo "done: $(ls dark/png | wc -l | tr -d ' ') dark, $(ls neutral/png | wc -l | tr -d ' ') neutral PNGs"
