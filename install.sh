#!/bin/sh
# Claude Switcher installer / updater. POSIX sh — works piped into sh, bash or zsh:
#
#   curl -fsSL https://raw.githubusercontent.com/naifuliang/claude-switcher/main/install.sh | sh
#
# Downloads the newest release with curl — which, unlike a browser, does not
# set the quarantine attribute — verifies its SHA-256 checksum, installs it,
# links the `claude-switcher` command and launches the app.
# Re-run the same command to update.
#
# Overrides:
#   CLAUDE_SWITCHER_INSTALL_DIR      target directory (default /Applications)
#   CLAUDE_SWITCHER_OPEN_APP         set 0 to skip launching after install
#   CLAUDE_SWITCHER_INSTALL_CONFIRM  set 1 to skip the confirmation prompt
#   CLAUDE_SWITCHER_RELEASE_TAG      install a specific tag instead of the newest
set -eu

APP_NAME="Claude Switcher"
EXE="ClaudeSwitcher"
REPO="naifuliang/claude-switcher"
INSTALL_DIR="${CLAUDE_SWITCHER_INSTALL_DIR:-/Applications}"
OPEN_APP="${CLAUDE_SWITCHER_OPEN_APP:-1}"
CONFIRM="${CLAUDE_SWITCHER_INSTALL_CONFIRM:-0}"
TAG="${CLAUDE_SWITCHER_RELEASE_TAG:-}"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/claude-switcher-install.XXXXXX")"
cleanup() { /bin/rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    echo "error: $APP_NAME is a macOS app" >&2
    exit 1
fi

echo "$APP_NAME installer"
echo ""
echo "This downloads the latest $APP_NAME release from GitHub,"
echo "verifies its SHA-256 checksum, and installs it into $INSTALL_DIR."
echo ""
if [ "$CONFIRM" != "1" ]; then
    if [ -r /dev/tty ]; then
        printf "Continue? [y/N] " > /dev/tty
        read REPLY < /dev/tty || REPLY=""
        case "$REPLY" in
            [Yy]*) ;;
            *) echo "Cancelled."; exit 0 ;;
        esac
    else
        echo "note: no terminal available for confirmation — continuing"
    fi
fi

API="https://api.github.com/repos/$REPO/releases"
if [ -n "$TAG" ]; then
    RELEASE_JSON="$(/usr/bin/curl -fsSL "$API/tags/$TAG")"
else
    echo "Resolving the newest release…"
    RELEASE_JSON="$(/usr/bin/curl -fsSL "$API?per_page=1")"
    TAG="$(printf '%s\n' "$RELEASE_JSON" | /usr/bin/grep -m1 '"tag_name"' | /usr/bin/cut -d'"' -f4)"
fi
if [ -z "$TAG" ]; then
    echo "error: could not determine the release to install" >&2
    exit 1
fi

ARCH="$(/usr/bin/uname -m)"
URLS="$(printf '%s\n' "$RELEASE_JSON" | /usr/bin/grep '"browser_download_url"' | /usr/bin/cut -d'"' -f4 | /usr/bin/grep '\.zip$' || true)"
URL="$(printf '%s\n' "$URLS" | /usr/bin/grep -e '-universal\.zip$' | /usr/bin/head -n1 || true)"
[ -n "$URL" ] || URL="$(printf '%s\n' "$URLS" | /usr/bin/grep -e "-$ARCH\.zip\$" | /usr/bin/head -n1 || true)"
if [ -z "$URL" ]; then
    echo "error: release $TAG has no build for $ARCH — build from source:" >&2
    echo "       git clone https://github.com/$REPO && cd claude-switcher && ./scripts/make-app.sh" >&2
    exit 1
fi
echo "Installing $APP_NAME $TAG"

ASSET="$(/usr/bin/basename "$URL")"
ARCHIVE_PATH="$WORK_DIR/$ASSET"
echo "Downloading…"
/usr/bin/curl -fsSL "$URL" --output "$ARCHIVE_PATH"
/usr/bin/curl -fsSL "$URL.sha256" --output "$ARCHIVE_PATH.sha256"

lower() { /usr/bin/tr '[:upper:]' '[:lower:]'; }
EXPECTED_HASH="$(/usr/bin/awk 'NF { print $1; exit }' "$ARCHIVE_PATH.sha256" | lower)"
if ! printf '%s\n' "$EXPECTED_HASH" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
    echo "The release checksum file is invalid. Installation stopped." >&2
    exit 1
fi
ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{ print $1 }' | lower)"
if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
    echo "The downloaded archive failed its SHA-256 check. Installation stopped." >&2
    exit 1
fi

/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$WORK_DIR/unpacked"
if [ ! -d "$WORK_DIR/unpacked/$APP_NAME.app" ]; then
    echo "error: archive did not contain $APP_NAME.app" >&2
    exit 1
fi

/bin/mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    /bin/mkdir -p "$INSTALL_DIR"
    echo "note: falling back to $INSTALL_DIR"
fi

# Quit a running copy so the new one can start (profiles are kept).
if /usr/bin/pgrep -x "$EXE" >/dev/null 2>&1; then
    echo "Quitting the running $APP_NAME…"
    /usr/bin/pkill -x "$EXE" 2>/dev/null || true
    i=0
    while /usr/bin/pgrep -x "$EXE" >/dev/null 2>&1 && [ $i -lt 20 ]; do /bin/sleep 0.25; i=$((i + 1)); done
fi

TARGET="$INSTALL_DIR/$APP_NAME.app"
echo "Installing to $TARGET…"
/bin/rm -rf "$TARGET"
/usr/bin/ditto "$WORK_DIR/unpacked/$APP_NAME.app" "$TARGET"
/usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# Command-line helper: claude-switcher status | list | use <name>
BIN_DIR="$HOME/.local/bin"
/bin/mkdir -p "$BIN_DIR"
/bin/ln -sf "$TARGET/Contents/MacOS/$EXE" "$BIN_DIR/claude-switcher"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: add $BIN_DIR to your PATH to use the claude-switcher command" ;;
esac

echo "✓ $APP_NAME $TAG installed"
if [ "$OPEN_APP" = "1" ]; then
    /usr/bin/open "$TARGET"
    echo "  Look for its icon in the menu bar."
fi
