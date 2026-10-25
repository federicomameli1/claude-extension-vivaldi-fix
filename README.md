# claude-extension-vivaldi-fix

Make the official **Claude for Chrome** extension render in **Vivaldi**'s side panel instead of opening blank.

> [!IMPORTANT]
> This is a maintained fork of [bigbrojake/claude-extension-vivaldi-fix](https://github.com/bigbrojake/claude-extension-vivaldi-fix). It adds the fixes needed for extension **1.0.94+**, where the panel shows "Can't reach the Claude extension" (see [below](#extension-1094-cant-reach-the-claude-extension)). They were submitted upstream in [bigbrojake/claude-extension-vivaldi-fix#2](https://github.com/bigbrojake/claude-extension-vivaldi-fix/pull/2).

> [!NOTE]
> This is a community patch, not affiliated with Anthropic or Vivaldi. It modifies a local copy of the extension's `manifest.json` on your own machine — no Anthropic code is redistributed by this repository.

## The problem

Installing the [Claude for Chrome](https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn) extension in Vivaldi looks fine — it appears in the extensions list, the toolbar icon renders — but clicking the icon opens a **blank / `about:blank` side panel**. The extension UI never loads.

## Root cause

The extension's `manifest.json` declares the `sidePanel` permission but does **not** declare a static `side_panel.default_path`. Instead, the service worker sets the panel path dynamically at runtime via `chrome.sidePanel.setOptions({ path: "sidepanel.html" })`.

Vivaldi's sidePanel API implementation does **not** honor dynamic `setOptions()` calls — it only uses the static path declared in the manifest. With no static path declared, Vivaldi has nothing to load, so the panel opens empty.

This is a known Vivaldi bug, tracked internally as **VB-120826** and discussed in:

- [Bug Report: Claude Extension for Chrome not working in Vivaldi Browser](https://forum.vivaldi.net/topic/111283/bug-report-claude-extension-for-chrome-not-working-in-vivaldi-browser)
- [chrome.sidePanel.setOptions is not effective in Vivaldi](https://forum.vivaldi.net/topic/109300/chrome.sidepanel.setoptions-is-not-effective-in-vivaldi.)
- [Extensions open a blank sidePanel when declaring the sidePanel permission](https://forum.vivaldi.net/topic/114345/extensions-open-a-blank-sidepanel-when-declaring-the-sidepanel-permission)

## The fix

Patch `manifest.json` on a local copy of the extension to add a static `side_panel.default_path`:

```jsonc
"side_panel": {
  "default_path": "sidepanel.html"
}
```

That's the entire functional change. The `"key"` field is preserved so the extension keeps its original ID (`fcoeoabgfenejglbffodgkkbkcdhcgfn`), which means the existing native-messaging registration (used to talk to the Claude Desktop app) continues to match without reconfiguration.

## Install

### Windows (PowerShell)

```powershell
git clone https://github.com/federicomameli1/claude-extension-vivaldi-fix.git
cd claude-extension-vivaldi-fix
.\scripts\install.ps1
```

The script will:
1. Auto-detect your Vivaldi profile and locate the installed Claude extension
2. Copy it to `%LOCALAPPDATA%\claude-extension-vivaldi-patched` (or a path you choose)
3. Patch `manifest.json` — add `side_panel.default_path`, remove `update_url`, strip the CRX signature dir
4. Verify the native-messaging host is registered for Vivaldi (warn if missing)
5. Print the manual steps below

### macOS / Linux

> [!WARNING]
> The bash script is provided but **untested**. Please open an issue with your output if you run it.

```bash
git clone https://github.com/federicomameli1/claude-extension-vivaldi-fix.git
cd claude-extension-vivaldi-fix
./scripts/install.sh
```

### Manual steps in Vivaldi (all platforms)

These can't be scripted — they're browser UI actions you need to do yourself.

1. Open `vivaldi://extensions`
2. **Disable** (do not remove) the existing **Claude** extension installed from the Chrome Web Store
3. Toggle **Developer mode** ON (top-right)
4. Click **Load unpacked** and select the patched folder (the install script prints the exact path)
5. Pin the new **Claude (Vivaldi-patched)** icon to the toolbar
6. Click it → the side panel should now render the Claude UI
7. Sign in and pair with Claude Desktop as prompted

## Verification

You'll see the normal Claude login / chat UI in Vivaldi's side panel. Two harmless CSP warnings may appear in the extension's error log — these occur in Chrome too and do not block functionality:

- `Executing inline script violates ... Content Security Policy` on `sidepanel.html:8` — the extension's dark-mode-preference inline script. Skipping it means no auto-detect of system dark mode on first paint.
- `Loading the script 'https://cdn.segment.com/...'` — analytics script blocked by the extension's own CSP.

## Extension 1.0.94+: "Can't reach the Claude extension"

Since 1.0.94 the side panel embeds claude.ai, and the static path alone is no longer enough: the panel renders but shows **"Can't reach the Claude extension."** ([anthropics/claude-code#95975](https://github.com/anthropics/claude-code/issues/95975)). Vivaldi hosts side panels inside a tab, which breaks two assumptions. `install.ps1` patches both:

1. **`tabId` binding.** The service worker opens `sidepanel.html?tabId=N` through `setOptions()`, which Vivaldi ignores. Without `tabId` the panel never connects to the service worker. The script adds `vivaldi-tabid.js`, which binds the panel to the active tab on load and rebinds it when the bound tab closes. To switch tabs, close and reopen the panel.
2. **Sender checks.** The service worker treats a sender as the side panel only when `sender.tab === undefined`. In Vivaldi the panel and its claude.ai frame both have a `tab`, so every request fails with `sender is not an extension page`. The script changes these checks to compare the sender URL with the extension's own pages, which still rejects content scripts and web pages.

Tested on Windows 11 with extension 1.0.100: chat, navigation, typing, page reading and screenshots all work. `install.sh` does not apply these patches yet.

## Troubleshooting

### The patched extension won't load — "duplicate extension ID" error
The Chrome Web Store copy is still enabled. Both copies share the same ID (pinned by the `"key"` field). Disable the CWS copy at `vivaldi://extensions` before loading the unpacked version.

### Panel still blank after loading
- Right-click the Claude toolbar icon and inspect the popup, or go to `vivaldi://extensions` → Claude (Vivaldi-patched) → **service worker** → Console
- Any red errors from `assets/sidepanel-*.js` are the real culprit. Open an issue with the output.

### Claude Desktop doesn't see the extension
The native-messaging host is registered separately from the extension. On Windows, check:

```powershell
reg query "HKCU\Software\Vivaldi\NativeMessagingHosts\com.anthropic.claude_browser_extension"
```

It should return a path to `com.anthropic.claude_browser_extension.json` under your Claude Desktop install. If missing on macOS/Linux, see the [stolot0mt0m/claude-chromium-native-messaging](https://github.com/stolot0mt0m/claude-chromium-native-messaging) project, which automates native-host manifest creation for alternative Chromium browsers.

### MCP `switch_browser` tool says "no other browsers available"
Only one browser extension is paired at a time. Fully quit Chrome (close all windows), open the Claude panel in Vivaldi, and if needed restart Claude Desktop to force a re-scan.

## Relationship to Anthropic

This project is not affiliated with Anthropic. No Anthropic code is distributed by this repository — only a script that applies a single-property change to a copy of the extension that the user has already installed from the Chrome Web Store. The original extension is not altered; the script produces a separate unpacked copy.

If Anthropic ships a release that declares `side_panel.default_path` (or Vivaldi fixes `chrome.sidePanel.setOptions`), this repo becomes unnecessary — please open an issue so we can add a notice.

## Credits

- [stolot0mt0m/claude-chromium-native-messaging](https://github.com/stolot0mt0m/claude-chromium-native-messaging) — related project that handles the native-messaging side for non-Chrome Chromium browsers
- Vivaldi community threads linked above for diagnosis context

## License

[MIT](LICENSE)
