# Contributing

Small, focused PRs are easiest to review. For anything bigger than a bug fix, open an issue first so we can agree on the approach.

## Build

You need macOS 14+ and Xcode's command line tools (`xcode-select --install`). Nothing else.

```sh
./build.sh                 # build/Telekey.app and dist/Telekey.zip
open build/Telekey.app
```

The first build downloads two pinned files into `vendor/` and checks their SHA-256: `adb` (Android platform-tools) and `scrcpy-server`. Later builds are offline.

No Xcode project, no packages. If `swiftc` fails with hundreds of errors from `/usr/local/include`, something (often an old Homebrew install) left C headers there. `build.sh` passes `-sdk`, which avoids it. Pass it too if you compile by hand.

## Where things are

| File | What it does |
|---|---|
| `Sources/App.swift` | Window, menus, the event monitor that captures input |
| `Sources/Model.swift` | Finding TVs (adb mDNS, Google Cast, port 5555), pairing, connecting, auto-reconnect |
| `Sources/Link.swift` | Starts scrcpy's server on the TV and speaks its control protocol (UHID keyboard and mouse) |
| `Sources/Remote.swift` | Turns Mac keyboard, trackpad and scroll events into HID reports and ⌘ shortcuts |
| `Sources/TV.swift` | Everything in the tabs: apps, Private DNS, links, storage, screenshots |
| `Sources/Configs.swift` | `~/Library/Application Support/Telekey/tvs.json`, one entry per TV |
| `Sources/Shell.swift` | Running adb, input validation, quoting |
| `Sources/UI/` | SwiftUI views. `Components.swift` holds the theme and shared pieces |

## How control works

1. `adb connect` to the TV (port 5555 if it's open, else Wireless debugging).
2. Push `scrcpy-server` to `/data/local/tmp` and start it with `video=false audio=false`. No screen is streamed, which is why input feels instant.
3. Forward a local port to the server's socket and send `UHID_CREATE` twice: a keyboard and a mouse. Android sees two real USB HID devices.
4. Every Mac event becomes a HID report (`UHID_INPUT`). Remote buttons use `INJECT_KEYCODE`.

The message format is in scrcpy's `app/src/control_msg.c`. It changes between scrcpy versions, so bumping `SCRCPY` in `build.sh` means checking `Link.swift` against the new version.

## Rules

- **Anything that goes into `adb shell` must be validated or quoted.** Package names go through `validPackage`, hosts through `validHost`, free text through `quoted()`. A link or app name is user input.
- **Destructive actions ask first.** Removing, clearing data and restarting all show a confirmation. Keep it that way.
- **Don't add dependencies.** No Swift packages, no Homebrew requirements for users. AppKit, SwiftUI, Network and the two bundled binaries are the whole stack.
- **Keep the look.** Flat graphite surfaces, one orange accent, no glass, blur or shadows. Use `Theme`, `Flat` buttons and `plate()`.
- **Test on a real TV** and say which one in the PR (brand, model, Android version). Scrolling and app lists behave differently on every brand.

## Good first issues

- Bloatware lists for brands other than TCL (`bloat` in `TV.swift`). Send package names with a one-line description each.
- Non-US keyboard layouts (`hidUsage` in `Remote.swift`).
- Scrolling in focus-based TV apps. See "Known issues" in the README.

## Reporting a bug

Include: Mac model and macOS version, TV brand and model, Android version, Telekey version (Telekey menu → About), and what you did. For connection problems, the output of `ANDROID_ADB_SERVER_PORT=5038 build/Telekey.app/Contents/Resources/adb devices -l` helps (Telekey runs its own adb server on port 5038).
