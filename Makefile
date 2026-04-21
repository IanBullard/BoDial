APP_NAME = BoDial
SOURCES  = $(wildcard Sources/*.swift)
BUILD    = build
BUNDLE   = $(BUILD)/$(APP_NAME).app
BINARY   = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
VERSION  = 1.0.0

# Minimum macOS version — matches Info.plist
MIN_MACOS = 13.0

SWIFTFLAGS = -O

# Code signing identity. Override on the command line for release builds, e.g.:
#   make CODESIGN_IDENTITY="Developer ID Application: Ian Bullard (E6UHUF3KD3)"
# Default is the local self-signed cert used for development. Using a named
# identity (rather than ad-hoc "-") keeps the signature stable across rebuilds,
# so TCC doesn't treat each build as a new app and churn Accessibility grants.
CODESIGN_IDENTITY ?= BoDial

# Extra codesign flags. Empty for dev builds; the `release` target sets this
# to enable the hardened runtime and a secure timestamp, both required for
# notarization.
CODESIGN_OPTS ?=

# Developer ID identity used by the `release` target. Obtain one via Xcode
# → Settings → Accounts → Manage Certificates → +Developer ID Application.
DEVID_IDENTITY ?= Developer ID Application: Ian Bullard (E6UHUF3KD3)

.PHONY: all clean release dump_raw watch_scrolls

# Default: universal binary (Apple Silicon + Intel)
all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_MACOS) $(SOURCES) -o $(BUILD)/BoDial-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_MACOS) $(SOURCES) -o $(BUILD)/BoDial-x86_64
	lipo -create $(BUILD)/BoDial-arm64 $(BUILD)/BoDial-x86_64 -output $(BINARY)
	@rm $(BUILD)/BoDial-arm64 $(BUILD)/BoDial-x86_64
	@cp Info.plist $(BUNDLE)/Contents/
	@codesign -f -s "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) $(BUNDLE)
	@touch $(BUNDLE)
	@echo "Built: $(BUNDLE) (universal, signed as $(CODESIGN_IDENTITY))"

clean:
	rm -rf $(BUILD)

# Release build: signed with the Developer ID identity, hardened runtime
# enabled, secure timestamp applied. Produces a zip suitable for
# notarization (run `make notarize` separately once notarytool
# credentials are stored — see README).
release: clean
	$(MAKE) CODESIGN_IDENTITY="$(DEVID_IDENTITY)" CODESIGN_OPTS="--options runtime --timestamp" $(BUNDLE)
	cd $(BUILD) && zip -qr $(APP_NAME)-$(VERSION).zip $(APP_NAME).app
	@echo "Release: $(BUILD)/$(APP_NAME)-$(VERSION).zip"
	@codesign -dv --verbose=2 $(BUNDLE) 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Timestamp|Runtime)"

# Build the diagnostic tool (not part of the app)
dump_raw: Tools/dump_raw.swift
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_MACOS) Tools/dump_raw.swift -o $(BUILD)/dump_raw-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_MACOS) Tools/dump_raw.swift -o $(BUILD)/dump_raw-x86_64
	lipo -create $(BUILD)/dump_raw-arm64 $(BUILD)/dump_raw-x86_64 -output $(BUILD)/dump_raw
	@rm $(BUILD)/dump_raw-arm64 $(BUILD)/dump_raw-x86_64
	@echo "Built: $(BUILD)/dump_raw (universal)"

# Listen-only session event tap that prints every scroll event reaching apps.
# Needs Accessibility permission granted to the binary itself.
watch_scrolls: Tools/watch_scrolls.swift
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_MACOS) Tools/watch_scrolls.swift -o $(BUILD)/watch_scrolls-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_MACOS) Tools/watch_scrolls.swift -o $(BUILD)/watch_scrolls-x86_64
	lipo -create $(BUILD)/watch_scrolls-arm64 $(BUILD)/watch_scrolls-x86_64 -output $(BUILD)/watch_scrolls
	@rm $(BUILD)/watch_scrolls-arm64 $(BUILD)/watch_scrolls-x86_64
	@echo "Built: $(BUILD)/watch_scrolls (universal)"
