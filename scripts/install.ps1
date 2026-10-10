<#
.SYNOPSIS
    Patch the Claude for Chrome extension so it renders correctly in Vivaldi.

.DESCRIPTION
    Copies the installed Claude extension from your Vivaldi profile to a separate
    folder, adds a static `side_panel.default_path` to manifest.json, and prints
    instructions for loading the patched copy as an unpacked extension.

    Does not download anything. Does not require admin. Only touches files under
    the current user's profile.

.PARAMETER Destination
    Target folder for the patched copy. Defaults to
    $env:LOCALAPPDATA\claude-extension-vivaldi-patched.

.PARAMETER Force
    Overwrite the destination folder without prompting if it already exists.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Destination C:\tools\claude-patched -Force
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'claude-extension-vivaldi-patched'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ExtensionId = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'

function Write-Step    ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok      ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2   ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2    ($msg) { Write-Host "    $msg" -ForegroundColor Red }

# --- 1. Locate Vivaldi's Claude extension install -----------------------------
Write-Step "Locating Vivaldi's installed Claude extension"

$vivaldiUserData = Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data'
if (-not (Test-Path $vivaldiUserData)) {
    Write-Err2 "Vivaldi user data not found at: $vivaldiUserData"
    Write-Err2 "Is Vivaldi installed for this user? Aborting."
    exit 1
}

# Search every profile (Default, Profile 1, etc.) for the extension
$extRoots = Get-ChildItem -Path $vivaldiUserData -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName "Extensions\$ExtensionId" } |
    Where-Object { Test-Path $_ }

if (-not $extRoots) {
    Write-Err2 "Claude extension ($ExtensionId) not found in any Vivaldi profile."
    Write-Err2 "Install it from the Chrome Web Store in Vivaldi first, then re-run this script."
    exit 1
}

# Pick the newest version folder across all profiles
$latest = $extRoots |
    ForEach-Object { Get-ChildItem -Path $_ -Directory } |
    Sort-Object { [version]($_.Name -replace '_\d+$','') } -Descending |
    Select-Object -First 1

Write-Ok "Found: $($latest.FullName)"

# --- 2. Confirm destination ---------------------------------------------------
Write-Step "Preparing destination: $Destination"
if (Test-Path $Destination) {
    if (-not $Force) {
        $reply = Read-Host "Destination exists. Overwrite? (y/N)"
        if ($reply -notmatch '^[yY]') { Write-Host "Aborted."; exit 0 }
    }
    Remove-Item -Recurse -Force $Destination
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# --- 3. Copy extension (skip _metadata which holds the CRX signature) --------
Write-Step "Copying extension files"
Get-ChildItem -Path $latest.FullName -Exclude '_metadata' | ForEach-Object {
    Copy-Item -Recurse -Force -Path $_.FullName -Destination $Destination
}
Write-Ok "Copied to $Destination"

# --- 4. Patch manifest.json ---------------------------------------------------
Write-Step "Patching manifest.json"
$manifestPath = Join-Path $Destination 'manifest.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Add static side_panel.default_path (the actual fix)
$manifest | Add-Member -NotePropertyName 'side_panel' `
    -NotePropertyValue ([pscustomobject]@{ default_path = 'sidepanel.html' }) -Force

# Remove update_url so Vivaldi doesn't try to auto-replace us with the CWS copy
if ($manifest.PSObject.Properties.Name -contains 'update_url') {
    $manifest.PSObject.Properties.Remove('update_url')
}

# Rename so it's visually distinct in the extensions list
$manifest.name = 'Claude (Vivaldi-patched)'

# Write back with UTF-8 (no BOM) — Chromium is picky about manifest encoding
$json = $manifest | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Added side_panel.default_path, removed update_url"

# --- 4b. Inject tabId when the static path omits it ---------------------------
# The service worker normally opens `sidepanel.html?tabId=N`; without tabId the panel
# never connects to the service worker and claude.ai shows "Can't reach the Claude
# extension". Gate the main module behind a loader that adds the active tab's id.
# ponytail: binds to the tab active when the panel opens; reopen the panel to rebind.
Write-Step "Patching sidepanel.html (tabId loader)"
$htmlPath = Join-Path $Destination 'sidepanel.html'
$html = [System.IO.File]::ReadAllText($htmlPath)
$m = [regex]::Match($html, '<script type="module" crossorigin src="(/assets/sidepanel-[^"]+\.js)"></script>')
if (-not $m.Success) { Write-Err2 "sidepanel module tag not found; extension layout changed."; exit 1 }
# Vivaldi remembers the panel URL, so a stale ?tabId survives reopening: always
# rebind to the active tab on load, and again when the bound tab is closed.
$loader = @"
(function () {
  var q = new URLSearchParams(location.search);
  function boot() {
    var s = document.createElement('script');
    s.type = 'module'; s.crossOrigin = ''; s.src = '$($m.Groups[1].Value)';
    document.head.appendChild(s);
  }
  function rebind(id) { q.set('tabId', id); location.replace('sidepanel.html?' + q); }
  if (q.get('mode') === 'window') return boot();
  chrome.tabs.query({ active: true, lastFocusedWindow: true }, function (tabs) {
    var active = tabs.filter(function (t) { return !t.url || !t.url.startsWith(location.origin); })[0];
    if (active && String(active.id) !== q.get('tabId')) return rebind(active.id);
    boot();
    chrome.tabs.onRemoved.addListener(function (id) {
      if (String(id) !== q.get('tabId')) return;
      chrome.tabs.query({ active: true, lastFocusedWindow: true }, function (t) { if (t[0]) rebind(t[0].id); });
    });
  });
})();
"@
[System.IO.File]::WriteAllText((Join-Path $Destination 'vivaldi-tabid.js'), $loader, (New-Object System.Text.UTF8Encoding $false))
$html = $html.Replace($m.Value, '<script src="/vivaldi-tabid.js"></script>')
[System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Added vivaldi-tabid.js loader"

# --- 4c. Accept the side panel as an extension page ---------------------------
# The service worker only trusts senders with no `tab` (true for Chrome's side panel),
# but Vivaldi hosts the panel in a tab, so every panel request is rejected
# ("sender is not an extension page"). Check the sender URL instead: still excludes
# content scripts and web pages.
Write-Step "Patching service worker sender check"
$swPath = (Get-ChildItem (Join-Path $Destination 'assets') -Filter 'service-worker*.js' | Select-Object -First 1).FullName
$sw = [System.IO.File]::ReadAllText($swPath)
$re = 'return void 0===(\w)\.tab&&\1\.id===chrome\.runtime\.id\}'
if (-not [regex]::IsMatch($sw, $re)) { Write-Err2 "sender check not found; extension layout changed."; exit 1 }
$sw = [regex]::Replace($sw, $re, 'return $1.id===chrome.runtime.id&&($1.url||"").startsWith(chrome.runtime.getURL(""))}')
# Same for claude.ai framed in the panel (onMessageExternal): its sender.tab is the
# panel's own tab, so trust it when that tab is sidepanel.html.
$inPanel = '(void 0===$1.tab||($1.tab.url||"").startsWith(chrome.runtime.getURL("sidepanel.html")))'
$n = 0
foreach ($p in @(
    @{ re = '(?<="get_sidepanel_host_info"===\w\.type\)try\{const \w=)void 0===(\w)\.tab'; to = $inPanel },
    @{ re = '(?<=\(ho\.includes\(\w\.type\)\)\{if\()void 0!==(\w)\.tab'; to = "!$inPanel" }
)) {
    if ([regex]::IsMatch($sw, $p.re)) { $sw = [regex]::Replace($sw, $p.re, $p.to); $n++ }
}
if ($n -lt 2) { Write-Warn2 "Only $n/2 external sender checks patched; extension layout changed." }
[System.IO.File]::WriteAllText($swPath, $sw, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Sender checks now URL-based"

# --- 5. Verify native messaging host registration ----------------------------
Write-Step "Checking native-messaging host registration for Vivaldi"
$nmKey = 'HKCU:\Software\Vivaldi\NativeMessagingHosts\com.anthropic.claude_browser_extension'
if (Test-Path $nmKey) {
    $nmPath = (Get-ItemProperty $nmKey).'(default)'
    if ($nmPath -and (Test-Path $nmPath)) {
        Write-Ok "Registered: $nmPath"
    } else {
        Write-Warn2 "Registry key exists but manifest file missing: $nmPath"
        Write-Warn2 "Install or repair Claude Desktop if MCP tools fail to connect."
    }
} else {
    Write-Warn2 "Native-messaging host NOT registered for Vivaldi."
    Write-Warn2 "Claude Desktop's MCP browser tools will not reach the Vivaldi extension."
    Write-Warn2 "On Windows, Claude Desktop usually creates this automatically when installed."
    Write-Warn2 "See https://github.com/stolot0mt0m/claude-chromium-native-messaging for manual setup."
}

# --- 6. Next steps ------------------------------------------------------------
Write-Host ""
Write-Host "Done. Manual steps in Vivaldi:" -ForegroundColor Cyan
Write-Host "  1. Open vivaldi://extensions"
Write-Host "  2. Disable (do not remove) the existing 'Claude' extension"
Write-Host "  3. Toggle Developer mode ON (top-right)"
Write-Host "  4. Click 'Load unpacked' and select:"
Write-Host "       $Destination" -ForegroundColor Yellow
Write-Host "  5. Pin the new 'Claude (Vivaldi-patched)' icon and click it"
Write-Host ""
