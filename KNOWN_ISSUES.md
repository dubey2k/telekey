# Known issues

Open problems in the code. Each one says where it is, what goes wrong, and the fix we'd accept. Pick one and open a PR. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to build.

For problems you might hit as a user, see [Good to know](README.md#good-to-know) in the README.

## Open

- [ ] **Port 5555 should be a setting.** `Model.connecting`
  After a Wireless-debugging connect, Telekey runs `adb tcpip 5555` so the TV stays reachable through sleep. It says so while connecting, and only approved devices can use the port, but people on shared Wi-Fi may want it off. Add a per-TV toggle in `TVConfig`.
- [ ] **Protected apps are matched by name.** `protected` in `Bloat.swift`
  Good enough for TCL and Google TV. Other brands may have essential apps it doesn't recognise. A per-brand list would be safer.
- [ ] **US keyboard layout only.** `hidUsage` in `Remote.swift`
  Keys are sent by physical position, and Android applies the TV's layout. Other Mac layouts type some symbols wrong.
- [ ] **Scrolling snaps back in Leanback and Compose-for-TV apps.** `Remote.scroll`
  These apps pull the list back to the focused row, and mouse-wheel events can't change that. Sending touch swipes at the pointer position (what MATVT does) might.

<details>
<summary><b>Fixed before 1.0</b></summary>
<br>

**From the production review**

- TV jobs used one global adb serial, so a slow job could finish on a different TV. Each session now owns its device.
- stdout and stderr shared one pipe, so an adb warning could corrupt a screenshot. They're read separately, and the exit status is checked.
- adb calls kept running after you left a screen. Cancel and Back now kill them, including a pairing in progress.
- adb's server was started twice at launch. The second copy aborted and left a crash report every time Telekey opened. Scans now wait for one server start.
- A failed load was cached, and adb's error text could show as data or become the TV's name. Failures now retry the next time the section opens.
- Settings were saved to `tvs.json` but never used. They're gone.
- Config writes could land out of order. They now go through one serial queue.
- Writes to the control socket could block the window and ignored partial writes. They now loop, time out after 1 s, and end the session on failure.
- ⌘Q did nothing while controlling the TV.
- Cast discovery gave up on a TV after one failed or IPv6-only attempt. It now forces IPv4 and retries.
- Scanning probed TVs one at a time. They're now probed all at once.
- The code didn't build in Swift 6 mode. It now builds in Swift 6 mode with no warnings, so data races are compile errors.

**Earlier**

- Control socket closed twice after a disconnect
- Shortcuts sent to a closed session
- An unreadable `tvs.json` overwritten (it's now kept as `tvs.json.unreadable`)
- Your own apps suggested as bloat
- A crash with Caps Lock and six keys held
- Clear data and Remove reachable on protected apps
- Custom DNS losing its text field
- Pasted text cut in the middle of a character
- Endless reconnects when a session died within seconds
- Sleeping TVs sent to the pairing screen
- adb calls that could hang forever (they now time out)
- adb restarted without asking (Telekey now runs its own adb server on port 5038)
- Port 5555 opened silently, with no fallback
- The per-app scroll-by-rows option (removed, it didn't help)

</details>
