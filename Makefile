APP     = Finch.app
BUNDLE  = $(APP)/Contents
BINARY  = $(BUNDLE)/MacOS/Finch

.PHONY: build install release test clean loc trace

# Code-signing identity. Prefers a Developer ID Application certificate, then
# an Apple Development one, else ad-hoc ("-"). `find-identity -v` lists revoked
# certificates too, so drop those. Override with `make install SIGN="…"`.
SIGN ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -v CSSMERR | grep -m1 -o '"Developer ID Application:[^"]*"' | tr -d '"'), \
	$(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -v CSSMERR | grep -m1 -o '"Apple Development:[^"]*"' | tr -d '"'),-)
# A real identity gets the hardened runtime. Notarization also needs a secure
# timestamp, which needs the network, so only Developer ID builds ask for one.
SIGN_FLAGS = $(if $(filter -,$(SIGN)),,--options runtime $(if $(findstring Developer ID,$(SIGN)),--timestamp))

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
UNREGISTER = $(LSREGISTER) -u "$(CURDIR)/$(APP)" >/dev/null 2>&1 || true
# After a failure: forget the build copy and point macOS back at the installed one.
RESTORE = $(UNREGISTER); $(LSREGISTER) -f /Applications/$(APP) >/dev/null 2>&1 || true

# `make release` notarizes with the 1Password item NOTARY_KEY=op://<vault>/<item>.
# Set it in the environment or in local.mk, which git ignores.
-include local.mk
NOTARIZE ?= /usr/bin/python3 -I tools/notarize.py

build:
	swift build -c release 2>&1
	@mkdir -p $(BUNDLE)/MacOS $(BUNDLE)/Resources
	@cp .build/release/Finch $(BINARY)
	@cp Info.plist $(BUNDLE)/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Resources/AppIcon.icns
	@codesign --force $(SIGN_FLAGS) --sign "$(SIGN)" $(APP)
	@echo "Built $(APP), signed by: $(SIGN)"

# Replace the installed copy and register it. There is deliberately no target
# that registers the repo's own Finch.app: two registered copies fight over
# com.finch.browser, and links go to whichever registered last. macOS can
# register the build copy by itself, so deploying also unregisters it.
define DEPLOY
@pkill -f "Finch.app/Contents/MacOS/Finch" 2>/dev/null || true
@sleep 0.3
@rm -rf /Applications/$(APP)
@cp -R $(APP) /Applications/
@$(UNREGISTER)
@$(LSREGISTER) -f /Applications/$(APP)
@open /Applications/$(APP)
endef

# Replace the installed copy, notarized when this Mac can notarize: a
# Developer ID identity and NOTARY_KEY=op://<vault>/<item> (environment or
# local.mk, which git ignores). Without either it installs signed only and says
# so, which is what a fresh clone gets. A notarization that is tried and fails
# stops here: nothing in /Applications is touched until Apple and Gatekeeper
# have both accepted. Stapling overwrites any ticket left from an earlier build.
CAN_NOTARIZE = $(and $(findstring Developer ID Application:,$(SIGN)),$(NOTARY_KEY))

install:
	@$(MAKE) build SIGN="$(SIGN)" || { $(RESTORE); exit 1; }
ifneq ($(CAN_NOTARIZE),)
	@trap '$(RESTORE)' EXIT; \
	$(NOTARIZE) $(APP) "$(NOTARY_KEY)" && \
	xcrun stapler staple $(APP) && \
	xcrun stapler validate $(APP) && \
	spctl --assess --type execute -v $(APP)
	$(DEPLOY)
	@echo "Notarized, installed and running /Applications/$(APP)"
else
	$(DEPLOY)
	@echo "Installed and running /Applications/$(APP), signed but NOT notarized"
	@echo "  (notarizing needs a Developer ID Application identity and NOTARY_KEY; signed by: $(SIGN))"
endif

# Kept so old habits still work: install already notarizes when it can.
release: install

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
