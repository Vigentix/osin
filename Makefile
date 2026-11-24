.PHONY: bootstrap generate open build build-release test lint format l10n-check snapshots clean

PROJECT := Osin.xcodeproj
SCHEME  := Osin

bootstrap: ## Install dev tools and generate the Xcode project
	brew bundle --file=Brewfile
	$(MAKE) generate

generate: ## Generate Osin.xcodeproj from project.yml
	xcodegen generate

open: generate ## Open the project in Xcode
	open $(PROJECT)

build: generate ## Debug build (unsigned)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=macOS' -derivedDataPath build \
		CODE_SIGNING_ALLOWED=NO build

build-release: generate ## Universal release build (unsigned)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath build \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

test: ## Run OsinCore unit tests
	swift test --package-path Packages/OsinCore

lint: ## Lint (CI runs the same)
	swiftformat --lint .
	swiftlint --strict

format: ## Auto-format
	swiftformat .
	swiftlint --fix

l10n-check: build ## Fail if any UI string is missing from the String Catalog
	python3 scripts/l10n.py missing

snapshots: build ## Render screens with live data to build/snapshots (Debug only)
	build/Build/Products/Debug/Osin.app/Contents/MacOS/Osin --render-snapshots build/snapshots

clean:
	rm -rf build Packages/OsinCore/.build $(PROJECT)
