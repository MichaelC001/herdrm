.PHONY: gen build run test kit-test uiux-test ssh-test mobile-build clean release install

# HerdrMobile / HerdrSSH are arm64-only (libssh2 + OpenSSL xcframeworks).
# Keep code signing on so Simulator Keychain (device SSH key) works; unsigned
# builds log errSecMissingEntitlement (-34018) on every launch.
MOBILE_BUILD = xcodebuild -project HerdrM.xcodeproj -scheme HerdrMobile \
	-configuration Debug \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath build-ios build \
	-skipPackagePluginValidation \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64

SSH_TEST = cd Packages/HerdrSSH && xcodebuild test \
	-scheme HerdrSSH \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath ../../build/HerdrSSHDerivedData \
	-collect-test-diagnostics never \
	-parallel-testing-enabled NO

CODE_SIGN_IDENTITY ?= -

gen:
	xcodegen generate

build: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5

# Optimised build, ad-hoc signed. The project enables the hardened runtime, whose
# library validation refuses the bundled Sparkle/Tailcat frameworks when the app
# has no Team ID (dyld: "different Team IDs"), so the tree is re-signed without
# the runtime option — fine for a locally built copy, not for distribution.
#
# Version stamps mirror CI (tag → MARKETING_VERSION, run number → CFBundleVersion)
# so the local build outranks the published release: project.yml's 0.1.0/1
# would make Sparkle offer the App Store-style release as an "update" and
# silently replace the fixed binary with the older one.
LOCAL_VERSION = $(shell git describe --tags --always | sed 's/^v//')
LOCAL_BUILD = $(shell git rev-list --count HEAD)
release: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Release -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation MARKETING_VERSION="$(LOCAL_VERSION)" CURRENT_PROJECT_VERSION="$(LOCAL_BUILD)" | tail -5
	codesign --force --deep --sign - build/Build/Products/Release/herdrm.app

# Replace /Applications/HerdrM.app with the local Release build. The copy it replaces
# is kept as build/HerdrM.previous.zip, refreshed on every install — zipped, not a
# second .app, so Launch Services and Sparkle never see two bundles with one ID.
install: release
	pkill -x herdrm || true
	sleep 1
	if [ -d /Applications/HerdrM.app ]; then ditto -c -k --keepParent /Applications/HerdrM.app build/HerdrM.previous.zip; fi
	rm -rf /Applications/HerdrM.app
	ditto build/Build/Products/Release/herdrm.app /Applications/HerdrM.app
	open /Applications/HerdrM.app

# `open` only activates an already-running app, so a rebuilt binary would never
# be exercised. Quit the previous Debug instance first (the /Applications copy is untouched).
run: build
	pkill -f 'build/Build/Products/Debug/herdrm.app/Contents/MacOS/herdrm' || true
	sleep 1
	open build/Build/Products/Debug/herdrm.app

# HerdrM UI/UX tests (HerdrMTests, hosted in the app): sidebar behavior through the real SidebarView.
UIUX_TEST = xcodebuild test \
	-project HerdrM.xcodeproj \
	-scheme HerdrM \
	-configuration Debug \
	-derivedDataPath build \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
	-skipPackagePluginValidation

uiux-test: gen
	$(UIUX_TEST)

kit-test:
	cd Packages/HerdrKit && swift test

# HerdrSSH Swift Testing on iOS Simulator (Session-driver e2e skips without a live sshd fixture).
ssh-test:
	$(SSH_TEST)

# Compile gate for HerdrMobile + HerdrSSH.
mobile-build: gen
	$(MOBILE_BUILD)

test: kit-test

clean:
	rm -rf build build-ios build/HerdrSSHDerivedData HerdrM.xcodeproj \
		Packages/HerdrKit/.build Packages/HerdrSSH/.build
