#!/bin/bash
set -euo pipefail

# make exports CODESIGN_IDENTITY, but this script is also run by hand, and an
# ad hoc signature is the one outcome that quietly breaks accessibility: it
# gives the app a new identity on every build, so the permission you granted
# stops applying to it. Look the certificate up rather than assume ad hoc.
best_identity() {
    local pattern
    for pattern in "Developer ID Application" "Apple Development"; do
        security find-identity -v -p codesigning 2>/dev/null |
            grep -o "\"$pattern: [^\"]*\"" | head -1 | tr -d '"' && return 0
    done
}

IDENTITY="${CODESIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="$(best_identity)"
[ -n "$IDENTITY" ] || IDENTITY="-"
BUNDLE=AutoRaise.app

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp AutoRaise "$BUNDLE/Contents/MacOS/"
cp Info.plist "$BUNDLE/Contents/"

# What the Finder tells people about which macOS they need, taken from what the
# binary will actually accept rather than from a number kept in step by hand. A
# plist claiming more than the binary allows means a launch that dies in dyld
# with nothing to read.
MINOS="$(vtool -show-build AutoRaise 2>/dev/null | awk '/minos/ {print $2; exit}')"
if [ -n "$MINOS" ]; then
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINOS" \
        "$BUNDLE/Contents/Info.plist" >/dev/null
    echo "Requires macOS $MINOS or later"
fi
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
    -)
        ;;
    *)
        # A timestamp keeps the signature valid after the certificate expires,
        # which matters for a copy installed on somebody else's Mac: without it
        # the accessibility permission stops applying the day the year is up.
        SIGN_ARGS+=(--timestamp)
        ;;
esac

if codesign "${SIGN_ARGS[@]}" "$BUNDLE"; then
    echo "Signed $BUNDLE with ${IDENTITY}"
    codesign --verify --strict "$BUNDLE" && echo "Signature verified"
else
    echo "Warning: $BUNDLE is unsigned; accessibility permission will not stick"
fi

if [ "$IDENTITY" = "-" ]; then
    echo "Warning: signed ad hoc. macOS will treat the next build as a different"
    echo "         app, and the accessibility permission will have to be granted"
    echo "         again. Install a development certificate to avoid that."
fi

echo "Successfully created $BUNDLE"
