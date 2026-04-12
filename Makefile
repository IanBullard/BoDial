APP_NAME = BoDial
SOURCES  = $(wildcard Sources/*.swift)
BUILD    = build
BUNDLE   = $(BUILD)/$(APP_NAME).app
BINARY   = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
VERSION  = 0.1.0

# Minimum macOS version — matches Info.plist
MIN_MACOS = 13.0

SWIFTFLAGS = -O

# Code signing identity. Override on the command line for release builds, e.g.:
#   make CODESIGN_IDENTITY="Developer ID Application: Ian Bullard (TEAMID)"
# Default is the local self-signed cert used for development. Using a named
# identity (rather than ad-hoc "-") keeps the signature stable across rebuilds,
# so TCC doesn't treat each build as a new app and churn Accessibility grants.
CODESIGN_IDENTITY ?= BoDial

.PHONY: all clean release dump_raw

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
	@codesign -f -s "$(CODESIGN_IDENTITY)" $(BUNDLE)
	@touch $(BUNDLE)
	@echo "Built: $(BUNDLE) (universal)"

clean:
	rm -rf $(BUILD)

release: $(BUNDLE)
	cd $(BUILD) && zip -r $(APP_NAME)-$(VERSION).zip $(APP_NAME).app
	@echo "Release: $(BUILD)/$(APP_NAME)-$(VERSION).zip"

# Build the diagnostic tool (not part of the app)
dump_raw: Tools/dump_raw.swift
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_MACOS) Tools/dump_raw.swift -o $(BUILD)/dump_raw-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_MACOS) Tools/dump_raw.swift -o $(BUILD)/dump_raw-x86_64
	lipo -create $(BUILD)/dump_raw-arm64 $(BUILD)/dump_raw-x86_64 -output $(BUILD)/dump_raw
	@rm $(BUILD)/dump_raw-arm64 $(BUILD)/dump_raw-x86_64
	@echo "Built: $(BUILD)/dump_raw (universal)"
