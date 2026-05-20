# CrisisX App - Judge Run Guide

This folder contains a prebuilt iOS Simulator app bundle:

- `CrisisX.app`
- Bundle ID: `downlabs.com-agenticpulse-crisis`
- Build type: Debug iOS Simulator
- Architectures: `arm64` and `x86_64`

## Requirements

- macOS with Xcode installed
- iOS Simulator available through Xcode

## Run on iOS Simulator

From this folder, open Simulator:

```sh
open -a Simulator
```

Option A: install into the currently booted simulator:

```sh
xcrun simctl install booted "CrisisX.app"
xcrun simctl launch booted downlabs.com-agenticpulse-crisis
```

Option B: automatically boot the first available iPhone simulator, then install and launch:

```sh
DEVICE=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Shutdown/ {print $2; exit}')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "CrisisX.app"
xcrun simctl launch "$DEVICE" downlabs.com-agenticpulse-crisis
```

## Demo Path For Judges

1. Submit a crisis report from the Report tab.
2. Open the live agent progress sheet and wait for completion.
3. Open the created incident.
4. Review Response Plan, Agent Trace, and Simulation Outcome.
5. In Simulation Outcome, the Provider Booking card shows three ranked mock providers, the selected provider, and a dispatch confirmation ID.

The backend Edge Function `ciro-agent` has been updated to simulate provider booking safely. No real emergency services are contacted.

## If The Simulator Name Differs

List available devices:

```sh
xcrun simctl list devices available
```

Then boot any available iPhone simulator and repeat the install and launch commands.

## Rebuild From Source If Needed

From the project root, run:

```sh
xcodebuild -project com.agenticpulse.crisis/com.agenticpulse.crisis.xcodeproj -scheme com.agenticpulse.crisis -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```
