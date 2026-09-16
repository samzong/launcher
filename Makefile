DIST := .local/dist
APP := $(DIST)/Launcher.app
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG := $(DIST)/Launcher-$(VERSION).dmg
TARGET := /Applications/Launcher.app

.PHONY: build check app dmg install uninstall clean

build:
	swift build -c release

check:
	swift test

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp .build/release/Launcher "$(APP)/Contents/MacOS/Launcher"
	codesign --force --sign - "$(APP)"

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
