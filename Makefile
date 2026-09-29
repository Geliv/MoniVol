# MoniVol Development Makefile
# Shortcuts for building, testing, and running MoniVol

.PHONY: help clean build run dev reset bundle install-deps sign verify release test-release quick rebuild dmg full-release changelog update-version

# Default target - show help
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  MoniVol Development Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "  Development:"
	@echo "    make dev          - Start from scratch (reset + build + run with onboarding)"
	@echo "    make run          - Run app without onboarding (keeps existing state)"
	@echo "    make reset        - Reset onboarding + uninstall driver"
	@echo ""
	@echo "  Building:"
	@echo "    make build        - Build driver, host, and app"
	@echo "    make bundle       - Create .app bundle in dist/"
	@echo "    make clean        - Clean all build artifacts"
	@echo "    make rebuild      - Full clean + rebuild"
	@echo "    make update-version - Update all component versions from git tag"
	@echo ""
	@echo "  Release (Code Signing):"
	@echo "    make release      - Build, sign, and verify for distribution"
	@echo "    make sign         - Code sign the .app bundle"
	@echo "    make verify       - Verify all code signatures"
	@echo "    make test-release - Test the signed release build"
	@echo ""
	@echo "  Distribution:"
	@echo "    make dmg          - Create DMG with drag-to-Applications layout"
	@echo "    make full-release - Complete pipeline (build + sign + DMG)"
	@echo ""
	@echo "  Other:"
	@echo "    make install-deps - Install build dependencies"
	@echo "    make changelog    - Update CHANGELOG.md (optional: VERSION=vX.Y.Z)"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Start from scratch - full developer workflow with onboarding
dev: reset build bundle
	@echo ""
	@echo "Starting MoniVol with onboarding..."
	@echo ""
	@open dist/MoniVol.app

# Run app normally without resetting onboarding
run:
	@echo "Starting MoniVol..."
	@if [ -d "dist/MoniVol.app" ]; then \
		open dist/MoniVol.app; \
	else \
		echo "❌ App bundle not found. Run 'make bundle' first."; \
		exit 1; \
	fi

# Update version from git tags
update-version:
	@echo "Updating version from git tags..."
	@./tools/update_versions.sh
	@echo "✓ Version updated"

# Build all components
build: update-version
	@echo "Building all components..."
	@./tools/build_release.sh

# Create .app bundle
bundle:
	@echo "Creating .app bundle..."
	@./tools/create_app_bundle.sh

# Clean all build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf packages/driver/build
	@rm -rf packages/host/.build
	@rm -rf apps/mac/MoniVolApp/.build
	@rm -rf dist
	@echo "✓ Clean complete"

# Reset onboarding and uninstall driver (for testing onboarding flow)
reset:
	@echo "Resetting MoniVol for fresh start..."
	@pkill -f "MoniVolApp|MoniVolHost" 2>/dev/null || true
	@./tools/uninstall_driver.sh || echo "No driver to uninstall (this is fine)"
	@defaults delete com.monivol.menubar hasCompletedOnboarding 2>/dev/null || true
	@defaults delete com.monivol.menubar onboardingVersion 2>/dev/null || true
	@defaults delete com.monivol.menubar driverInstallDate 2>/dev/null || true
	@sleep 2
	@echo "✓ Reset complete - next launch will show onboarding"

# Install build dependencies
install-deps:
	@echo "Checking build dependencies..."
	@which cmake > /dev/null || (echo "❌ CMake not found. Install with: brew install cmake" && exit 1)
	@which swift > /dev/null || (echo "❌ Swift not found. Install Xcode." && exit 1)
	@echo "✓ All dependencies installed"

# Quick rebuild (for when you only changed Swift code)
quick:
	@echo "Quick rebuild (Swift only, universal)..."
	@cd apps/mac/MoniVolApp && swift build -c release --triple arm64-apple-macosx && swift build -c release --triple x86_64-apple-macosx && mkdir -p .build/universal/release && lipo -create -output .build/universal/release/MoniVolApp .build/arm64-apple-macosx/release/MoniVolApp .build/x86_64-apple-macosx/release/MoniVolApp
	@cd packages/host && swift build -c release --triple arm64-apple-macosx && swift build -c release --triple x86_64-apple-macosx && mkdir -p .build/universal/release && lipo -create -output .build/universal/release/MoniVolHost .build/arm64-apple-macosx/release/MoniVolHost .build/x86_64-apple-macosx/release/MoniVolHost
	@./tools/create_app_bundle.sh
	@echo "✓ Quick rebuild complete (universal)"

# Full clean + rebuild
rebuild: clean build bundle
	@echo "✓ Full rebuild complete"

# Code signing targets
sign:
	@echo "Code signing MoniVol.app..."
	@./tools/codesign.sh

verify:
	@echo "Verifying signatures..."
	@./tools/verify_signatures.sh

# Build and sign (for release)
release: build bundle sign verify
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "     Release Build Complete!"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "Signed app: dist/MoniVol.app"
	@echo ""
	@echo "Next steps:"
	@echo "  • Test: make test-release"
	@echo "  • Notarize: ./tools/notarize.sh (Phase 2)"
	@echo "  • Package DMG: ./tools/create_dmg.sh (Phase 3)"
	@echo ""

# Test the signed release build
test-release:
	@echo " Testing signed release build..."
	@open dist/MoniVol.app

# Create DMG for distribution
dmg:
	@echo "Creating DMG..."
	@./tools/create_dmg.sh

# Full release pipeline (build, sign, create DMG)
full-release: build bundle sign verify dmg
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Full Release Build Complete!"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@ls -lh dist/*.dmg

# Update changelog
changelog:
	@echo "Updating CHANGELOG.md..."
	@./tools/generate_changelog.sh $(if $(VERSION),--tag $(VERSION),)
	@echo "✓ CHANGELOG.md updated"
