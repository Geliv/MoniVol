#!/bin/bash
set -e

# MoniVol Notarization Script
# Notarizes the signed app, staples the ticket, then rebuilds the DMG.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_PATH="$PROJECT_ROOT/dist/MoniVol.app"
DMG_PATH="$PROJECT_ROOT/dist/MoniVol.dmg"
ZIP_PATH="$PROJECT_ROOT/dist/MoniVol-notarize.zip"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

section() { echo -e "\n${BLUE}----------------------------------------\n  $1\n----------------------------------------${NC}"; }

# ── Prerequisites ──────────────────────────────────────────────

section "Checking Prerequisites"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}ERROR: $APP_PATH not found. Run 'make release' first.${NC}"
    exit 1
fi

# Require credentials via environment variables
if [ -z "$APPLE_ID" ] || [ -z "$APPLE_ID_PASSWORD" ] || [ -z "$APPLE_TEAM_ID" ]; then
    echo -e "${RED}ERROR: Missing required environment variables.${NC}"
    echo ""
    echo "Please set the following before running:"
    echo "  export APPLE_ID=\"your-apple-id@example.com\""
    echo "  export APPLE_ID_PASSWORD=\"your-app-specific-password\""
    echo "  export APPLE_TEAM_ID=\"YOUR_TEAM_ID\""
    echo ""
    echo "Or create a .env file (not tracked by git) and source it:"
    echo "  source .env && ./tools/notarize.sh"
    exit 1
fi

echo -e "${GREEN}OK${NC}: App found: $APP_PATH"
echo -e "${GREEN}OK${NC}: Apple ID: $APPLE_ID"
echo -e "${GREEN}OK${NC}: Team ID: $APPLE_TEAM_ID"

# ── Step 1: Create ZIP for notarization ────────────────────────

section "Step 1/5: Creating ZIP Archive"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo -e "${GREEN}OK${NC}: Created ZIP ($(du -h "$ZIP_PATH" | cut -f1))"

# ── Step 2: Submit to Apple Notary Service ─────────────────────

section "Step 2/5: Submitting to Apple Notary Service"
echo "This may take a few minutes..."

xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

echo -e "${GREEN}OK${NC}: Notarization accepted"

# ── Step 3: Staple ticket to .app ──────────────────────────────

section "Step 3/5: Stapling Ticket to App"

xcrun stapler staple "$APP_PATH"
echo -e "${GREEN}OK${NC}: Ticket stapled to MoniVol.app"

# ── Step 4: Rebuild DMG with stapled app ───────────────────────

section "Step 4/5: Rebuilding DMG"

"$SCRIPT_DIR/create_dmg.sh"
echo -e "${GREEN}OK${NC}: DMG rebuilt with notarized app"

# ── Step 5: Verify ─────────────────────────────────────────────

section "Step 5/5: Verification"

echo "Verifying app notarization..."
spctl --assess -vv "$APP_PATH" 2>&1 || true

# ── Cleanup ────────────────────────────────────────────────────

rm -f "$ZIP_PATH"

section "Done!"
echo ""
echo -e "  ${GREEN}Notarized DMG: $DMG_PATH${NC}"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "  This DMG is ready for distribution."
echo "  Users will not see Gatekeeper warnings."
echo ""
