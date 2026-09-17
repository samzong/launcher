DIST := .local/dist
APP := $(DIST)/Launcher.app
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG := $(DIST)/Launcher-$(VERSION).dmg
TARGET := /Applications/Launcher.app
TESTING_MACROS := $(shell dirname $(shell xcrun --find swift))/../lib/swift/host/plugins/testing/libTestingMacros.dylib

.PHONY: build check app dmg install uninstall clean

build:
	swift build -c release

check:
	swift test -Xswiftc -load-plugin-library -Xswiftc "$(TESTING_MACROS)"

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp .build/release/Launcher "$(APP)/Contents/MacOS/Launcher"
	@identity=$$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development: / { print $$2; exit }'); \
	echo "Launcher: signing as $${identity:-adhoc, accessibility grant resets on every install}"; \
	codesign --force --sign "$${identity:--}" "$(APP)"

dmg: app
	rm -rf "$(DIST)/stage" "$(DMG)"
	mkdir -p "$(DIST)/stage"
	cp -R "$(APP)" "$(DIST)/stage/"
	ln -s /Applications "$(DIST)/stage/Applications"
	diskutil image create from --format UDZO --volumeName Launcher "$(DIST)/stage" "$(DMG)"

install: app
	-pkill -f "$(TARGET)/Contents/MacOS/Launcher"
	rm -rf "$(TARGET)"
	cp -R "$(APP)" "$(TARGET)"
	open "$(TARGET)"

uninstall:
	-pkill -f "$(TARGET)/Contents/MacOS/Launcher"
	rm -rf "$(TARGET)"

clean:
	rm -rf .build "$(DIST)"
