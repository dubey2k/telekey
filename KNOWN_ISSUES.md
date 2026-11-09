# Known issues in the code

Found in a review before the first release. Each line says where, what goes wrong, and the fix we'd take. Pick one, open a PR.

## Worth fixing first

- **One global `serial` for TV jobs** (`Shell.swift`, `TV.swift`). A slow job for TV A (Remove all, Clear caches) that's still running when you switch to TV B finishes on TV B. `Link` already keeps its own; `TV` should too.
- **Port 5555 should be a setting** (`Model.connect`, `adb tcpip 5555`). It's announced while connecting and only approved devices can use it, but people on shared Wi-Fi may want it off.
- **adb calls aren't cancelled with their task** (`run()`). They time out after 20 s, but leaving a screen doesn't stop them sooner.

## Smaller

- **Back during pairing doesn't cancel it** (`Model.pair`). If `adb pair` succeeds afterwards, the app jumps to connecting.
- **Cast discovery tries each TV once** (`CastBrowser.resolve`). A failed or IPv6-only first attempt means the TV only shows up via adb until restart. Force IPv4 and retry on failure.
- **stdout and stderr share one pipe** (`run()`). An adb warning on stderr corrupts a screenshot PNG or the forwarded port number. Read them separately.
- **Failed loads are cached** (`TV.load`). If the first adb call for a section fails, it's never retried, and error text can end up shown as data or saved as the TV's name.
- **Settings recorded but never re-applied** (`TVConfig.privateDNS`, `screensaver`, `animations`, `turnedOffApps`, `removedApps`). Either restore them on a factory-reset TV, or drop them.
- **Config writes aren't ordered** (`Configs.save`). They run on a concurrent queue; use a serial one and `sync` on flush.
- **Writes to the control socket are blocking and unchecked** (`Link.send`). Partial writes are ignored and a stalled adb freezes the UI.
- **⌘Q does nothing while controlling the TV.** Every key goes to the TV until ⌘ is pressed alone. Let ⌘Q through.
- **Swift 6 mode doesn't build.** `Link` is `@unchecked Sendable` with unguarded fields; `act()` closures aren't `@MainActor`. Builds in Swift 5 mode today.
- **Protected apps are matched by name** (`protected` in `TV.swift`). Good enough for TCL and Google TV; other brands may have essentials it doesn't recognise.
- **Keyboard is US layout** (`hidUsage` in `Remote.swift`).
- **Scrolling in Leanback/Compose-for-TV apps snaps back** to the focused row. Mouse-wheel events can't fix it; synthetic touch swipes at the pointer (what MATVT does) might.

## Fixed before release

Double close of the control socket after a disconnect; shortcuts still sent to a closed session; an unreadable `tvs.json` being overwritten (now kept as `tvs.json.unreadable`); the user's own apps suggested as bloat; a crash with Caps Lock and six keys held; clear-data and remove reachable on protected apps; custom DNS losing its field; pasted text cut mid-character; endless reconnect when a session dies within seconds; sleeping TVs sent to the pairing screen; adb calls that could hang forever (now time out); tunnel cleanup blocking the window; adb restarted without asking (Telekey now runs its own adb server on port 5038, so it never touches other tools' adb); port 5555 opened silently with no fallback; the per-app scroll-by-rows option (removed, it didn't help).
