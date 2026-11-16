#!/usr/bin/env bash
# Builds the web app for https://gabirodz.github.io/learnmath/ and puts it in
# the learnmath/ folder of a checkout of the site's repository
# (Gabirodz/Gabirodz.github.io). It does not commit or push: look at
# `git status` there, then commit and push to deploy.
#
# Usage: tool/build_pages.sh <path to the site checkout>
set -euo pipefail

site=${1:?usage: tool/build_pages.sh <path to the site checkout>}
[ -f "$site/_config.yml" ] || { echo "error: $site is not the site checkout" >&2; exit 2; }
cd "$(dirname "$0")/.."

flutter build web --release --no-wasm-dry-run --base-href /learnmath/ -o build/web-pages

out="$site/learnmath"
rm -rf "$out"
cp -r build/web-pages "$out"
# Not used by the hosted app: CanvasKit comes from Google's CDN, the app has
# no service worker of Flutter's, sherpa-onnx is the phone's voice engine, and
# the WebView plugin's error page is for Android.
rm -rf "$out/canvaskit" "$out/.last_build_id" "$out/flutter_service_worker.js" \
  "$out/assets/packages/sherpa_onnx_web" "$out/assets/packages/flutter_inappwebview"
echo "Wrote $out ($(du -sh "$out" | cut -f1)). Commit and push in $site to deploy."
