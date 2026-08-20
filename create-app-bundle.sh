#!/bin/bash
set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE=AutoRaise.app

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp AutoRaise "$BUNDLE/Contents/MacOS/"
cp Info.plist "$BUNDLE/Contents/"
cp AutoRaise.icns "$BUNDLE/Contents/Resources/"
[ -f quirks.json ] && cp quirks.json "$BUNDLE/Contents/Resources/"
chmod 755 "$BUNDLE"

# macOS identifies an accessibility client by its code signature. An unsigned
# bundle gets a new identity on every build, which is why granting access used
# to mean first deleting the stale entry in System Settings. Signing with a
# stable certificate makes the grant stick.
SIGN_ARGS=(--force --sign "$IDENTITY")
case "$IDENTITY" in
    "Developer ID Application"*)
        SIGN_ARGS+=(--options runtime --timestamp)
        ;;
esac

if codesign "${SIGN_ARGS[@]}" "$BUNDLE"; then
    echo "Signed $BUNDLE with ${IDENTITY}"
    codesign --verify --strict "$BUNDLE" && echo "Signature verified"
else
    echo "Warning: $BUNDLE is unsigned; accessibility permission will not stick"
fi

echo "Successfully created $BUNDLE"
