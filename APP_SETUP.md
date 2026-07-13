# App Setup — Installing VisionClaude on Your iPhone (Development)

This guide covers everything needed to build the **VisionClaude iOS app** and run it
on your own iPhone for development/testing. It focuses on the app itself; the Mac-side
channel server (which the app talks to) is covered at the end.

> **Scope:** You only need the iPhone camera to test the core app. Meta Ray-Ban glasses
> are **optional** and require extra steps (see [Optional: Meta Ray-Ban Glasses](#optional-meta-ray-ban-glasses)).

---

## 1. Prerequisites

| Requirement | Notes | Check |
|---|---|---|
| **macOS 13+** | — | `sw_vers` |
| **Full Xcode 26.6** | Installed at `/Applications/Xcode.app`. **Command Line Tools alone is NOT enough.** | see §2 |
| **An Apple ID** | A free personal Apple ID works for on-device dev (7-day signing). A paid Apple Developer account lasts longer and is required for Meta glasses. | — |
| **iPhone on iOS 17+** | Physical device — the app uses the camera, so the Simulator can't run it meaningfully. | — |
| **USB cable** | For first install / trusting the device. | — |
| **xcodegen** | Regenerates the Xcode project from `project.yml`. Already installed here (`xcodegen 2.45.4`). | `xcodegen --version` |

**Project facts** (from `ClaudeVision/ios/project.yml`):
- Bundle ID: `co.hyperfood.claudevision`
- Deployment target: iOS 17.0
- Dependency: `meta-wearables-dat-ios` SPM package (fetched automatically by Xcode)

---

## 2. Point the toolchain at full Xcode

On this machine, `xcodebuild` currently resolves to Command Line Tools, which **cannot
build the app**:

```bash
xcodebuild -version
# xcode-select: error: tool 'xcodebuild' requires Xcode ...
```

Xcode 26.6 lives at **`/Applications/Xcode.app`**. Point the toolchain at it, accept the
license, and run first-launch component setup:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -version        # should now print Xcode 26.6
```

> If Xcode was downloaded as an `.xip` (e.g. into `~/Downloads`), extract it and move
> `Xcode.app` into `/Applications` before running the commands above — `xcode-select`
> needs the exact path `/Applications/Xcode.app/Contents/Developer`.

---

## 3. Generate & open the Xcode project

The `.xcodeproj` is committed, but regenerating from `project.yml` guarantees it matches
the current config:

```bash
cd ClaudeVision/ios
xcodegen generate
open ClaudeVision.xcodeproj
```

On first open, Xcode resolves the Swift Package dependency
(`meta-wearables-dat-ios` → `MWDATCore`, `MWDATCamera`). Let it finish
(*File ▸ Packages ▸ Resolve Package Versions* if it stalls).

---

## 4. Set your signing team

`DEVELOPMENT_TEAM` ships empty, so the build won't sign until you set it. You have two options:

### Option A — In Xcode (quickest)
1. Select the **ClaudeVision** target ▸ **Signing & Capabilities**.
2. Check **Automatically manage signing**.
3. Pick your **Team** (your Apple ID / personal team).

> ⚠️ This edit lives in the generated `.xcodeproj`. Running `xcodegen generate` again
> **wipes it**. Use Option B if you regenerate often.

### Option B — In `project.yml` (survives regeneration) — recommended
Find your Team ID:
```bash
# Xcode ▸ Settings ▸ Accounts ▸ (your account) ▸ Manage Certificates,
# or list teams from the CLI:
security find-identity -v -p codesigning
```
Then set it in `ClaudeVision/ios/project.yml`:
```yaml
    settings:
      base:
        DEVELOPMENT_TEAM: "YOURTEAMID"   # e.g. A1B2C3D4E5
```
Regenerate:
```bash
cd ClaudeVision/ios && xcodegen generate
```

> The `MWDAT > TeamID` value in `Info.plist` is `$(DEVELOPMENT_TEAM)`, so setting the
> team once feeds both code-signing and the Meta SDK config.

---

## 5. Build & run on the device

1. Connect your iPhone via USB. Unlock it and tap **Trust This Computer** if prompted.
2. In Xcode's device dropdown (top toolbar), select your iPhone.
3. Press **⌘R** (Run).

**First-run device trust:** With a free/personal team, iOS won't launch the app until you
trust the developer profile:

> On the iPhone: **Settings ▸ General ▸ VPN & Device Management ▸** (your Apple ID) ▸ **Trust**.

Then relaunch from Xcode or tap the app icon.

**Permissions:** On first launch the app requests Camera, Microphone, Speech Recognition,
Local Network, and Bluetooth. Approve them — the corresponding usage strings are already
in `Info.plist`.

---

## 6. Connect the app to your Mac (channel server)

The app is a client; it needs the VisionClaude **channel server** running on your Mac to
do anything useful. Both must be on the **same Wi-Fi network**.

**Start the server** (from `<repo-root>`, MCP is already configured in `.mcp.json`):
```bash
# <repo-root> is your clone of this repo, e.g. ~/projects/visionclaude
bun run <repo-root>/ClaudeVision/channel/server.ts
```
It prints a **Channel Token** and serves a dashboard at <http://localhost:18790>.
(In normal use it's launched automatically as the `visionclaude` MCP server inside Claude Code.)

**Find your Mac's IP** (the app needs this, not `localhost`):
```bash
ipconfig getifaddr en0     # Wi-Fi; try en1 if blank
```

**In the app ▸ Settings**, enter:

| Setting | Value |
|---|---|
| **Host** | Your Mac's IP (e.g. `192.168.1.42`) — or the `.local` name |
| **Port** | `18790` |
| **Channel Token** | From the server output / dashboard |

Tap **Connect** — a green indicator means you're live. Point the camera at something and
ask *"What am I looking at?"*.

> The app's default host is `Davids-MacBook-Air.local` (`Models/ClaudeConfig.swift`).
> If your Mac's hostname differs, set the Host field to your actual IP or `.local` name.

---

## Optional: Meta Ray-Ban Glasses

Not needed for iPhone-camera testing. To use glasses:

1. **Meta AI app** → pair glasses via Bluetooth → enable **Developer Mode** for your glasses,
   then restart the glasses.
2. **Meta developer dashboard** (<https://developers.meta.com>): create an app → add
   **Wearables** → iOS config with your **Team ID** + Bundle ID `co.hyperfood.claudevision`.
3. The app's `MWDAT` config in `Info.plist` must match your Meta app:
   - `MetaAppID` — your Meta app ID
   - `ClientToken` — `AR|<MetaAppID>|<token>`
   - `AppLinkURLScheme` — **`claudevision://`** (a custom URL scheme; already registered in
     `CFBundleURLTypes`). Register this **exact** string as the redirect URI in the Meta
     dashboard for that app. *No HTTPS universal link, domain, or Associated Domains
     entitlement is required for the custom scheme — those are only needed if you switch
     `AppLinkURLScheme` to an `https://` link.*
4. In the app: **Settings ▸ Connect Glasses via Meta AI ▸ Approve**, then switch the camera
   source to **Meta Ray-Ban**.

> Meta glasses registration requires a **paid** Apple Developer account (the Team ID must be
> registered with Meta).

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodebuild requires Xcode` | Run the `xcode-select -s` command in §2. |
| "Failed to register bundle identifier" / signing errors | Set your Team (§4). The bundle ID must be globally unique — this project uses `co.hyperfood.claudevision`. If that's taken under your team, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to something unique like `co.<you>.claudevision`, then regenerate. |
| App won't launch: "Untrusted Developer" | Trust the profile: **Settings ▸ General ▸ VPN & Device Management** (§5). |
| App installed but won't connect | Same Wi-Fi? Server running? Using the Mac's **IP** (not `localhost`)? Correct **token**? |
| "Local Network" prompt denied | Re-enable: iPhone **Settings ▸ VisionClaude ▸ Local Network** → on. |
| Package resolution fails | *File ▸ Packages ▸ Reset Package Caches*, then resolve again. |
| Free-account app "expires" after 7 days | Rebuild/reinstall from Xcode, or use a paid Apple Developer account. |
| Glasses callback never returns to app | The `AppLinkURLScheme` in `Info.plist` must **exactly** match the redirect URI registered in the Meta dashboard for that App ID. |

---

## Quick reference

```bash
# One-time toolchain fix
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Generate & open
cd ClaudeVision/ios && xcodegen generate && open ClaudeVision.xcodeproj

# Set team in project.yml (DEVELOPMENT_TEAM), regenerate, then ⌘R in Xcode

# Start the channel server (or let Claude Code launch it via .mcp.json)
bun run <repo-root>/ClaudeVision/channel/server.ts

# Mac IP for the app's Host field
ipconfig getifaddr en0
```
