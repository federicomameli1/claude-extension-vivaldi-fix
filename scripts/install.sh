#!/usr/bin/env bash
# Patch the Claude for Chrome extension so it renders correctly in Vivaldi.
#
# UNTESTED on macOS / Linux — please open an issue with your output if you run it.
#
# Copies the installed Claude extension from your Vivaldi profile to a separate
# folder, adds a static side_panel.default_path to manifest.json, and prints
# instructions for loading the patched copy as an unpacked extension.

set -euo pipefail

EXT_ID="fcoeoabgfenejglbffodgkkbkcdhcgfn"
DEST="${1:-${HOME}/claude-extension-vivaldi-patched}"

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }

step() { cyan "==> $*"; }
ok()   { green "    $*"; }
warn() { yellow "    $*"; }
err()  { red   "    $*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

require_cmd jq

# --- Detect Vivaldi user data dir --------------------------------------------
case "$(uname -s)" in
    Darwin)  VIVALDI_DATA="${HOME}/Library/Application Support/Vivaldi" ;;
    Linux)
        if   [[ -d "${HOME}/.config/vivaldi"        ]]; then VIVALDI_DATA="${HOME}/.config/vivaldi"
        elif [[ -d "${HOME}/.config/vivaldi-stable" ]]; then VIVALDI_DATA="${HOME}/.config/vivaldi-stable"
        elif [[ -d "${HOME}/.config/vivaldi-snapshot" ]]; then VIVALDI_DATA="${HOME}/.config/vivaldi-snapshot"
        else err "Vivaldi config dir not found under ~/.config/"; exit 1
        fi
        ;;
    *) err "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

[[ -d "$VIVALDI_DATA" ]] || { err "Vivaldi data not found: $VIVALDI_DATA"; exit 1; }

# --- Find the extension (newest version across all profiles) -----------------
step "Locating Vivaldi's installed Claude extension"
mapfile -t candidates < <(find "$VIVALDI_DATA" -type d -path "*/Extensions/${EXT_ID}/*" \
    -maxdepth 5 2>/dev/null | sort -V)

if [[ ${#candidates[@]} -eq 0 ]]; then
    err "Claude extension ($EXT_ID) not found in any Vivaldi profile."
    err "Install it from the Chrome Web Store in Vivaldi first, then re-run."
    exit 1
fi

LATEST="${candidates[-1]}"
ok "Found: $LATEST"

# --- Destination -------------------------------------------------------------
step "Preparing destination: $DEST"
if [[ -d "$DEST" ]]; then
    read -r -p "Destination exists. Overwrite? (y/N) " reply
    [[ "$reply" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
    rm -rf "$DEST"
fi
mkdir -p "$DEST"

# --- Copy (skip _metadata CRX signature dir) ---------------------------------
step "Copying extension files"
(cd "$LATEST" && find . -mindepth 1 -maxdepth 1 ! -name '_metadata' \
    -exec cp -R {} "$DEST"/ \;)
ok "Copied to $DEST"

# --- Patch manifest.json -----------------------------------------------------
step "Patching manifest.json"
MANIFEST="$DEST/manifest.json"
tmp="$(mktemp)"
jq '
    .side_panel = { default_path: "sidepanel.html" }
    | del(.update_url)
    | .name = "Claude (Vivaldi-patched)"
' "$MANIFEST" > "$tmp"
mv "$tmp" "$MANIFEST"
ok "Added side_panel.default_path, removed update_url"

# --- Native messaging check (best-effort) ------------------------------------
step "Checking native-messaging host registration for Vivaldi"
case "$(uname -s)" in
    Darwin)
        NM_PATH="${HOME}/Library/Application Support/Vivaldi/NativeMessagingHosts/com.anthropic.claude_browser_extension.json"
        ;;
    Linux)
        NM_PATH="${VIVALDI_DATA}/NativeMessagingHosts/com.anthropic.claude_browser_extension.json"
        ;;
esac

if [[ -f "$NM_PATH" ]]; then
    ok "Manifest present: $NM_PATH"
else
    warn "Native-messaging host NOT registered for Vivaldi at:"
    warn "  $NM_PATH"
    warn "Claude Desktop's MCP browser tools will not reach the Vivaldi extension."
    warn "See https://github.com/stolot0mt0m/claude-chromium-native-messaging for setup."
fi

# --- Next steps --------------------------------------------------------------
echo
cyan "Done. Manual steps in Vivaldi:"
echo "  1. Open vivaldi://extensions"
echo "  2. Disable (do not remove) the existing 'Claude' extension"
echo "  3. Toggle Developer mode ON (top-right)"
echo "  4. Click 'Load unpacked' and select:"
yellow "       $DEST"
echo "  5. Pin the new 'Claude (Vivaldi-patched)' icon and click it"
