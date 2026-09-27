#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 [--tag vX.Y.Z] [--no-fetch-tags]"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 --tag v2.1.1"
}

TAG=""
FETCH_TAGS=true

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --tag)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --tag requires a value"
                usage
                exit 1
            fi
            TAG="$1"
            ;;
        --no-fetch-tags)
            FETCH_TAGS=false
            ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage
            exit 1
            ;;
    esac
    shift
done

if ! command -v git-cliff > /dev/null 2>&1; then
    echo "Error: git-cliff not installed"
    echo "Install with: brew install git-cliff"
    exit 1
fi

cd "$PROJECT_ROOT"

if [ "$FETCH_TAGS" = true ]; then
    if git remote get-url origin > /dev/null 2>&1; then
        echo "INFO: Fetching latest tags from origin..."
        git fetch --tags --force --prune origin > /dev/null 2>&1 || \
            echo "WARN: Failed to fetch tags from origin. Continuing with local tags."
    else
        echo "INFO: No origin remote configured. Using local tags only."
    fi
fi

TMP_FILE="$(mktemp)"
cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [ -n "$TAG" ]; then
    echo "Generating changelog up to $TAG..."
    git cliff --config .github/cliff.toml --tag "$TAG" > "$TMP_FILE"
else
    echo "Generating full changelog..."
    git cliff --config .github/cliff.toml > "$TMP_FILE"
fi

if [ -f CHANGELOG.md ] && cmp -s "$TMP_FILE" CHANGELOG.md; then
    echo "OK: CHANGELOG.md is already up to date"
    exit 0
fi

mv "$TMP_FILE" CHANGELOG.md
echo "OK: CHANGELOG.md updated"
echo "Review changes and commit with: git add CHANGELOG.md && git commit -m 'docs: update changelog'"
