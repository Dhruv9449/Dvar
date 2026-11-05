APP_NAME   := Chrome Router
BIN        := chrome-router
BUILD      := build
APP        := $(BUILD)/$(APP_NAME).app
PREFIX     ?= $(HOME)/Applications
BIN_DIR    ?= $(HOME)/.local/bin
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SOURCES    := $(wildcard Sources/*.swift)

.PHONY: build app install uninstall test clean

build: $(BUILD)/$(BIN)

$(BUILD)/$(BIN): $(SOURCES)
	@mkdir -p $(BUILD)
	swiftc -O -framework AppKit -o $@ $(SOURCES)

app: $(BUILD)/$(BIN) Resources/Info.plist
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp $(BUILD)/$(BIN) "$(APP)/Contents/MacOS/$(BIN)"
	codesign --force --sign - "$(APP)"

install: app
	@mkdir -p "$(PREFIX)" "$(BIN_DIR)"
	@pkill -x $(BIN) 2>/dev/null || true
	rm -rf "$(PREFIX)/$(APP_NAME).app"
	cp -R "$(APP)" "$(PREFIX)/"
	$(LSREGISTER) -f "$(PREFIX)/$(APP_NAME).app"
	ln -sf "$(PREFIX)/$(APP_NAME).app/Contents/MacOS/$(BIN)" "$(BIN_DIR)/$(BIN)"
	@echo
	@echo "Installed $(PREFIX)/$(APP_NAME).app and $(BIN_DIR)/$(BIN)"
	@case ":$$PATH:" in *":$(BIN_DIR):"*) ;; *) echo "Note: add $(BIN_DIR) to your PATH";; esac
	@echo "Next: $(BIN) init && $(BIN) set-default-browser"

uninstall:
	@pkill -x $(BIN) 2>/dev/null || true
	-$(LSREGISTER) -u "$(PREFIX)/$(APP_NAME).app"
	rm -rf "$(PREFIX)/$(APP_NAME).app" "$(BIN_DIR)/$(BIN)"
	@echo "Removed. Pick another default browser in System Settings → Desktop & Dock."

test: $(BUILD)/$(BIN)
	./tests/run.sh $(BUILD)/$(BIN)

clean:
	rm -rf $(BUILD)
