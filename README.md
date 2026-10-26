# Neptune Control

A standalone macOS app and optional desktop widget for managing Neptune collection in Claude Code and Cursor. The interface and documentation are in English.

## Download and install

[Download Neptune Control 1.2.0](https://github.com/milosdostanic-cyber/neptune-control-pipeline/releases/tag/v1.2.0)

1. Download and extract `Neptune-Control-1.2.zip` from the release.
2. Move `Neptune Control.app` to your Applications folder and open it.
3. Choose **Connect Neptune** and sign in with your own SpaceInch Neptune account.
4. To add the optional widget, choose **Add widget**, then right-click the desktop, select **Edit Widgets** and search for **Neptune Control**. Small, Medium and Large sizes are available.

Requires **macOS 14 or later**. The release includes Apple silicon and Intel support. Existing Neptune hooks and their connection must already be installed on the Mac for collection controls to work.

The downloadable app is ad-hoc signed and is not notarized. macOS may block a downloaded copy. A standard trusted distribution requires Developer ID signing and Apple notarization.

## What the app does

- Detects Claude Code and Cursor account states independently.
- Allows Neptune collection only for verified SpaceInch hook events. Personal or unverified events skip collection while work continues.
- Provides a collection switch for each app. Manual off choices persist across restarts.
- Compares Claude Code and Cursor token totals from the connected Neptune account for the **last 30 calendar days**, including today. Totals include input, output and cache tokens.
- Shows a compact status widget on the desktop or in Notification Center.
- Opens the Neptune website in the default browser when **My stats** is selected.

The chart belongs to the Neptune account signed into the app. A personal account currently selected in Claude or Cursor does not change that chart into personal-account statistics.

## How it works

![Neptune Hooks and Neptune Control pipeline](docs/images/neptune-pipeline.png)

Read the [high-level pipeline](docs/pipeline.md), edit the [Mermaid source](docs/pipeline.mmd), or open the [editable Figma diagram](https://www.figma.com/design/E587bvgdGPwtnpo4bfd4lh/Untitled?node-id=3-2).

Every managed hook launches a short-lived guard that checks the identity attached to that event. Approved events reach the saved original Neptune scripts. The guard continues to work when the app is closed.

The running app separately reads your Neptune statistics and writes a credential-free local widget snapshot. Keep the app running for fresh statistics and widget states. Statistics are requested about every five minutes; macOS controls widget refresh timing. A green status dot indicates local collection readiness, not confirmation of successful server delivery.

## Build from source

Use a Mac with Xcode Command Line Tools and Swift 5.9 or later. Node.js is needed only for the statistics bridge tests.

```sh
swift test
node Tests/stats-bridge.test.mjs
bash scripts/build-app.sh
```

The app bundle is generated at `build/Neptune Control.app`, with the WidgetKit extension embedded. The build script creates universal Apple silicon / Intel binaries and applies an ad-hoc signature.

The optional `NeptuneWidget.xcodeproj` contains a native widget extension target. The build script packages the complete standalone app.

## Project structure

| Path | Purpose |
| --- | --- |
| `Sources/NeptuneControl` | SwiftUI app, controls and Neptune statistics connection |
| `Sources/NeptuneControlCore` | Per-event account policy, hook management and shared status models |
| `Sources/NeptuneWidget` | WidgetKit status widget |
| `Resources` | Neptune branding, app icons, statistics bridge and widget configuration |
| `Tests` | Isolated account, hook, widget and statistics tests |
| `scripts` | Universal app build and icon generation |
| `docs` | Pipeline diagram and English documentation |

## Account protection and local data

Collection is restricted to verified `@spaceinch.com` hook identities. Cursor requires matching company identities in the event and process environment. Claude Code requires a company identity and account UUID; unsupported API-key or external-provider authentication is denied.

Existing Neptune credentials stay in their local configuration. Neptune statistics sign-in uses the app's local WebKit store; credentials are not sent through the native statistics bridge or copied to the widget. Backups, original scripts and preferences stay in the current user's Application Support folder. The repository and release include no user sign-ins, credentials, prompts or local account bindings.

The app manages the inspected global Claude Code and Cursor hook paths on the local Mac. It does not control independent collection software or remote machines. Another installer with the same user permissions can replace these paths; this guard is not an operating-system security boundary.

Claude desktop identities that cannot be independently verified remain unverified. The original Cursor Neptune Hooks extension can overwrite guarded hooks; if detected, the app disables collection and reports the conflict.
