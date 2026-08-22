#!/bin/bash
#
# Builds the disk image AutoRaise is handed to another Mac on.
#
# Two things stand between a copied app and a working one, and neither is
# obvious from the outside: macOS blocks the first launch of anything it has not
# seen notarised, and AutoRaise does nothing at all without accessibility
# permission. Both are in the Read Me next to the app, and this script says
# which of them will happen before the image is handed over.
set -euo pipefail

BUNDLE=AutoRaise.app
STAGE=build/dmg
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
IMAGE="AutoRaise-$VERSION.dmg"

[ -d "$BUNDLE" ] || { echo "No $BUNDLE; run make first"; exit 1; }

# An ad hoc signature gives the app a new identity on every build, and the
# accessibility permission granted on the other Mac would stop applying to it
# the next time it is replaced.
if codesign -dvv "$BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
    echo "Refusing to build $IMAGE: $BUNDLE is signed ad hoc."
    echo "Whoever installs it would have to grant accessibility again after"
    echo "every update. Build it with a certificate: rm -rf $BUNDLE && make"
    exit 1
fi

rm -rf "$STAGE" "$IMAGE"
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me.txt" <<EOF
AutoRaise $VERSION

Hovering a window gives it the keyboard, or brings it to the front, without a
click. Everything else it does is in its Settings window.

Installing
  1. Drag AutoRaise onto the Applications folder beside it.
  2. Open Applications and launch AutoRaise. It lives in the menu bar, not the
     Dock, so the only sign of it is the arrow at the top right.

The first launch is blocked
  This build is signed, but not notarised by Apple, so macOS stops it once.
  Open System Settings > Privacy & Security, scroll down to the line saying
  AutoRaise was blocked, and choose Open Anyway.

  To skip that, run this in Terminal before launching it:

      xattr -dr com.apple.quarantine /Applications/AutoRaise.app

Then allow accessibility
  System Settings > Privacy & Security > Accessibility, switch AutoRaise on.
  Nothing works without it: reading which window is under the pointer is an
  accessibility operation. AutoRaise says so in its menu bar item, and its
  Explain What It Is Doing panel says it in as many words.

If hovering still does nothing
  Open the menu bar item and choose Explain What It Is Doing. The panel names
  the window under the pointer, what AutoRaise decided, and the rule that
  decided it, including the rules that say to do nothing.

Where things are kept
  ~/.config/AutoRaise/config      settings, plain text, reloaded when saved
  ~/.config/AutoRaise/apps.json   how individual applications are treated
  ~/.config/AutoRaise/stats.json  how many clicks hovering has saved you

  Nothing leaves the machine. There is no network code in AutoRaise at all.

Removing it
  Quit it from the menu bar, drag /Applications/AutoRaise.app to the Bin, and
  delete ~/.config/AutoRaise if you want its settings gone too.
EOF

hdiutil create -volname "AutoRaise $VERSION" -srcfolder "$STAGE" \
    -ov -quiet -format UDZO "$IMAGE"

echo "Wrote $IMAGE ($(du -h "$IMAGE" | cut -f1))"
echo
codesign -dvv "$BUNDLE" 2>&1 | grep -E "^Authority=|^Identifier=" | head -2

# What the other Mac will actually do, rather than what we hope it does.
if spctl -a -vv "$BUNDLE" >/dev/null 2>&1; then
    echo "Gatekeeper: accepted, this installs without a warning"
else
    echo "Gatekeeper: the first launch will be blocked, as the Read Me describes."
    echo "            Notarising removes that step: see make notarize"
fi
