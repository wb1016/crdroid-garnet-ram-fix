#!/usr/bin/env bash
# Pack the Magisk module (module/) into a flashable zip.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^version=//p' module/module.prop)
OUT="crdroid-garnet-ram-fix-${VERSION}.zip"

rm -f "$OUT"
(cd module && zip -r9 "../$OUT" . -x '*.DS_Store' -x '*/.git/*')

echo "Built: $(pwd)/$OUT"
unzip -l "$OUT"
