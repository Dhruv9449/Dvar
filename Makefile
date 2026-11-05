APP_NAME   := Dvar
BIN        := dvar
BUNDLE_ID  := com.dhruv9449.dvar
VERSION    := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/Core/Dvar.swift)

BUILD      := build
APP        := $(BUILD)/$(APP_NAME).app
PREFIX     ?= $(HOME)/Applications
BIN_DIR    ?= $(HOME)/.local/bin

SOURCES    := $(shell find Sources -name '*.swift')
SWIFTFLAGS := -O -swift-version 6 -parse-as-library -framework AppKit -framework SwiftUI
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build app install uninstall test clean

build: $(BUILD)/$(BIN)

$(BUILD)/$(BIN): $(SOURCES)
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -o $@ $(SOURCES)

app: $(BUILD)/$(BIN) Resources/Info.plist Resources/AppIcon.icns
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp $(BUILD)/$(BIN) "$(APP)/Contents/MacOS/$(BIN)"
	@# Ad-hoc signatures default to a cdhash requirement, so macOS privacy grants
	@# (Full Disk Access) would reset on every rebuild. Pin it to the bundle id.
	codesign --force --sign - -r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"

install: app
	@mkdir -p "$(PREFIX)" "$(BIN_DIR)"
	@pkill -x $(BIN) 2>/dev/null || true
	rm -rf "$(PREFIX)/$(APP_NAME).app"
	cp -R "$(APP)" "$(PREFIX)/"
	$(LSREGISTER) -f "$(PREFIX)/$(APP_NAME).app"
	ln -sf "$(PREFIX)/$(APP_NAME).app/Contents/MacOS/$(BIN)" "$(BIN_DIR)/$(BIN)"
	@echo
	@echo "Installed $(PREFIX)/$(APP_NAME).app $(VERSION) and $(BIN_DIR)/$(BIN)"
	@case ":$$PATH:" in *":$(BIN_DIR):"*) ;; *) echo "Note: add $(BIN_DIR) to your PATH";; esac
	@echo "Next: $(BIN) ui  (add rules, then click Make default)"

uninstall:
	@pkill -x $(BIN) 2>/dev/null || true
	-$(LSREGISTER) -u "$(PREFIX)/$(APP_NAME).app"
	rm -rf "$(PREFIX)/$(APP_NAME).app" "$(BIN_DIR)/$(BIN)"
	@echo "Removed. Pick another default browser in System Settings → Desktop & Dock."

test: $(BUILD)/$(BIN)
	./tests/run.sh $(BUILD)/$(BIN)

clean:
	rm -rf $(BUILD)
