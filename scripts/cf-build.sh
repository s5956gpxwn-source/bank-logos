#!/bin/sh
# Cloudflare Pages build step: publish ONLY the logo files.
# Pages settings: build command "sh scripts/cf-build.sh", output directory "dist".
# Docs, scripts and app code stay private in the repo.
set -e
rm -rf dist
mkdir dist
cp -R light dark neutral dist/
cp banks.json dist/
cp scripts/_headers dist/_headers
echo "dist ready: $(find dist -type f | wc -l | tr -d ' ') files"
