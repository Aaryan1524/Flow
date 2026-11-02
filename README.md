# Flow

Hold **Fn**, speak, let go: your words appear at the cursor in any Mac app. Speech recognition runs on this Mac (Parakeet on the Neural Engine), so audio never leaves it.

Early work in progress. Flow cleans the transcript with fast rules (fillers, stutters, spoken punctuation like "comma" and "new paragraph"), and you can paste the uncleaned version from the menu. AI-assisted self-correction ("Tuesday, no wait, Wednesday") is built but switched off until its safety check has had a final review.

## Build

Needs macOS 26, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
xcodegen generate
open Flow.xcodeproj      # then run the Flow scheme
swift test               # unit tests
```

The first launch downloads the speech model.

## Permissions

Flow asks for Microphone, Input Monitoring (to see the Fn key) and Accessibility (to paste). Also set System Settings > Keyboard > "Press 🌐 key to" to **Do Nothing**.

macOS ties these permissions to the app's signature. In Xcode, sign in under Settings > Accounts, then set your team on the Flow target, or every rebuild will ask again.

## Layout

```
App/        menu-bar app and wiring
Sources/    Hotkey, Audio, ASR, Cleanup, Insertion, History, FlowKit (shared types)
Tools/      flow-eval (compare engines on your recordings), flow-record
```
