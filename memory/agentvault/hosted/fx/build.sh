#!/bin/sh
# Bundles fx.src.js with three.js and GSAP into static/fx.js (one minified file, served from this site: the CSP allows no other origin).
set -e
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
(cd "$T" && npm init -y >/dev/null && npm i --silent three@0.187.0 gsap@3.15.1 esbuild)
cp fx.src.js "$T/"
"$T/node_modules/.bin/esbuild" "$T/fx.src.js" --bundle --minify --format=esm --target=es2022 --legal-comments=none --outfile=../static/fx.js
ls -l ../static/fx.js
