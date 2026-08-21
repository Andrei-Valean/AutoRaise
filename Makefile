SKYLIGHT_AVAILABLE := $(shell test -d /System/Library/PrivateFrameworks/SkyLight.framework && echo 1 || echo 0)

CXX ?= g++
override CXXFLAGS += -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" \
                     -D"SKYLIGHT_AVAILABLE=$(SKYLIGHT_AVAILABLE)" -Isrc

FRAMEWORKS := -framework AppKit -framework ServiceManagement -framework QuartzCore \
              -framework UniformTypeIdentifiers
ifeq ($(SKYLIGHT_AVAILABLE), 1)
    FRAMEWORKS += -F /System/Library/PrivateFrameworks -framework SkyLight
endif

SOURCES := src/main.mm src/Config.mm src/FocusRing.mm src/MenuBar.mm src/Policy.mm \
           src/Quirks.mm src/Shortcut.mm src/SettingsUI.mm src/SettingsWindow.mm \
           src/Stats.mm \
           src/WindowFinder.mm
HEADERS := src/Config.h src/FocusRing.h src/MenuBar.h src/Policy.h src/Quirks.h src/Stats.h \
           src/SettingsUI.h src/SettingsWindow.h src/WindowFinder.h
OBJECTS := $(patsubst src/%.mm,build/%.o,$(SOURCES))

# Signing is what stops macOS from treating every build as a brand new app and
# losing the accessibility permission you already granted. A Developer ID is
# used when present, otherwise a development certificate, otherwise ad hoc.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
    grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
ifeq ($(strip $(CODESIGN_IDENTITY)),)
    CODESIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | \
        grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
endif
ifeq ($(strip $(CODESIGN_IDENTITY)),)
    CODESIGN_IDENTITY := -
endif
export CODESIGN_IDENTITY

.PHONY: all clean install uninstall build run debug update test icon dmg notarize identity

all: AutoRaise AutoRaise.app

build/%.o: src/%.mm $(HEADERS)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Linked and signed inside build/, because codesign treats any directory that
# holds an Info.plist as a bundle and then writes a signature that refers to it,
# which the kernel rejects the moment the binary is moved or the plist changes.
AutoRaise: $(OBJECTS)
	$(CXX) $(CXXFLAGS) -o build/AutoRaise $(OBJECTS) $(FRAMEWORKS)
	@codesign --force --sign "$(CODESIGN_IDENTITY)" \
	    --identifier nl.postware.autoraise build/AutoRaise && \
	    echo "Signed AutoRaise with $(CODESIGN_IDENTITY)" || \
	    echo "Warning: could not sign AutoRaise, macOS will not run it"
	cp build/AutoRaise $@

AutoRaise.app: AutoRaise Info.plist AutoRaise.icns
	./create-app-bundle.sh

# The pure decision layer, exercised without accessibility permission.
test: build/policy_tests
	@./build/policy_tests

build/policy_tests: tests/policy_tests.mm src/Policy.mm src/Quirks.mm src/Config.mm \
                    src/Shortcut.mm src/Stats.mm $(HEADERS)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ tests/policy_tests.mm src/Policy.mm src/Quirks.mm src/Config.mm \
	    src/Shortcut.mm src/Stats.mm \
	    -framework Foundation -framework CoreGraphics -framework Carbon

icon: AutoRaise.icns

AutoRaise.icns: tools/make-icon.mm
	@mkdir -p build
	$(CXX) -O2 -fobjc-arc -o build/make-icon tools/make-icon.mm -framework AppKit
	./build/make-icon build/AutoRaise.iconset
	iconutil -c icns build/AutoRaise.iconset -o AutoRaise.icns
	@echo "Wrote AutoRaise.icns"

install: AutoRaise.app
	rm -rf /Applications/AutoRaise.app
	cp -r AutoRaise.app /Applications/
	@echo "Installed. Open /Applications/AutoRaise.app and allow accessibility."

uninstall:
	-pkill -x AutoRaise
	rm -rf /Applications/AutoRaise.app

dmg: AutoRaise.app
	rm -rf build/dmg AutoRaise.dmg
	mkdir -p build/dmg
	cp -r AutoRaise.app build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname AutoRaise -srcfolder build/dmg -ov -format UDZO AutoRaise.dmg

# Needs a Developer ID certificate and a stored notarytool profile:
#   xcrun notarytool store-credentials AutoRaise --apple-id ... --team-id ... --password ...
notarize: dmg
	@case "$(CODESIGN_IDENTITY)" in \
	    "Developer ID Application"*) ;; \
	    *) echo "notarize needs a Developer ID Application certificate, found: $(CODESIGN_IDENTITY)"; exit 1;; \
	esac
	xcrun notarytool submit AutoRaise.dmg --keychain-profile "$(AR_NOTARY_PROFILE)" --wait
	xcrun stapler staple AutoRaise.dmg
	spctl -a -t open --context context:primary-signature -v AutoRaise.dmg

identity:
	@echo "$(CODESIGN_IDENTITY)"

clean:
	rm -f AutoRaise
	rm -rf AutoRaise.app build

run: all
	./AutoRaise -focusDelay 1

debug: all
	./AutoRaise -focusDelay 1 -verbose true

update: all install
