APP     = Finch.app
BUNDLE  = $(APP)/Contents
BINARY  = $(BUNDLE)/MacOS/Finch

.PHONY: build install test clean loc trace

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

build:
	swift build -c release 2>&1
	@mkdir -p $(BUNDLE)/MacOS $(BUNDLE)/Resources
	@cp .build/release/Finch $(BINARY)
	@cp Info.plist $(BUNDLE)/Info.plist
	@codesign --deep --force --sign - $(APP)
	@echo "Built $(APP)"

# Replace the installed copy and register it. There is deliberately no target
# that registers the repo's own Finch.app: two registered copies fight over
# com.finch.browser, and links go to whichever registered last.
install: build
	@pkill -f "Finch.app/Contents/MacOS/Finch" 2>/dev/null || true
	@sleep 0.3
	@rm -rf /Applications/$(APP)
	@cp -R $(APP) /Applications/
	@$(LSREGISTER) -f /Applications/$(APP)
	@open /Applications/$(APP)
	@echo "Installed and running /Applications/$(APP)"

# Resolve a URL against the live config and print the result; opens nothing.
# Runs the bare binary rather than the bundle, so nothing new gets registered.
test:
	@swift build -c release >/dev/null 2>&1 || swift build -c release
	@.build/release/Finch --test "$(URL)"

clean:
	rm -rf .build $(APP)

# Count source lines. The headline figure is CODE lines — comments and blanks
# excluded — because that is what a reader has to understand.
loc:
	@total=$$(cat Sources/Finch/*.swift | wc -l | tr -d ' '); \
	code=$$(cat Sources/Finch/*.swift | grep -vcE '^[[:space:]]*(//.*)?$$'); \
	echo "code $$code   total $$total   (comments+blank $$((total-code)))" 

# Stream the route trace live. One line per URL: total, then per-stage deltas.
trace:
	@log stream --predicate 'subsystem == "com.finch.browser"' --style compact --info
