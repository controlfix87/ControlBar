# Handoff: ControlBar (working name)

This note is for the next agent working on this repo. It describes the state as of **2026-09-23**. Read `README.md` for the user-facing overview; this file covers what isn't in there: what's verified, what isn't, the macOS quirks we found, and what's next.

## What the user asked for

A macOS menu bar app that does two things:
1. **Keep-awake** (like Caffeine): prevent sleep.
2. **Hidden icons strip**: hide menu bar icons (the Hidden Bar technique), and when asked, show them in a **strip below the menu bar**. The strip auto-hides after **5 s** and/or on a **click outside**.

User decisions (don't re-ask):
- **Minimum macOS 14.** The user's Mac runs macOS 26.5 (Tahoe) on a notched MacBook, with an external Dell display.
- **It will be open source** (MIT). `LICENSE` holds a placeholder copyright line, "The ControlBar contributors".
- **Credit `dwarvesf/hidden` only if code is actually copied from it.** Nothing has been copied so far; we only use the idea of a divider that expands to push icons off-screen. If you copy code from it, add attribution in README and LICENSE.
- The project lives in `~/perch-temp`. "ControlBar" is a temporary name.
- Latest request, already implemented: the ┃ divider should be **visible while the strip is shown**.

## State

- Builds cleanly with no warnings (Swift 6.3 compiler, Swift 5 language mode, tools-version 5.10).
- `git init` has been run, but **nothing is committed**. The user hasn't asked for a commit yet, so ask before committing.
- The last build is running on the user's Mac (`build/ControlBar.app`).
- The user has granted **Accessibility** and **Screen Recording** to ControlBar. The grants survive rebuilds because of stable signing (see below).

### Verified
| Area | How it was checked |
|---|---|
| Keep-awake assertion | `pmset -g assertions` shows `PreventUserIdleDisplaySleep "ControlBar keep-awake"` while on; gone after quit |
| Divider expansion hides icons on macOS 26 | Diagnostics report: the divider grows (the system caps it at ~5016 pt) and items move to x≈-4000 |
| Finding hidden items and their owner apps | Diagnostics found all 7 hidden items with the correct apps |
| Capture while items are on-screen | 7/7 captured, PNGs inspected visually; they look right |
| Initial placement away from the notch | ControlBar's items land at x≈1060–1170 on the built-in screen (visible) |

### NOT verified yet (the user is testing now)
The agent's shell can't click the menu bar or take screenshots, so the user has to test these:
- The strip appearing, its position under the chevron, and its look (light or dark matching the menu bar).
- The ┃ divider being visible while the strip is open (the latest change).
- Auto-hide after 5 s, hide on click outside, hide on Esc, and pausing while the pointer hovers.
- **Clicking an item in the strip** (`ItemActivator`): reveal, then `AXPress` (with a synthetic-click fallback), then wait for the menu to close, then re-hide. This is the most likely thing to need fixes.
- Arrange mode, the ⌥⌘B hotkey, the Settings window, and launch at login.

## Architecture (Sources/ControlBar)

```
App/        main.swift (AppKit entry, .accessory policy), AppDelegate (wiring),
            Diagnostics (text report + --diagnose CLI mode)
KeepAwake/  SleepPreventer: IOPMAssertion, timer for durations; KeepAwakeDuration presets
MenuBar/    StatusBarController: 3 NSStatusItems (keep-awake ☕, chevron ⌄, divider ┃), hide/reveal
                                 state, right-click menu
            MenuBarScanner: AX-based enumeration of every app's status items, window-ID matching
            ItemImageCapturer: ScreenCaptureKit capture + in-memory cache keyed by item id
            ItemActivator: opens a hidden item from the strip
            AX: small Accessibility helpers
Strip/      StripController: panel lifecycle, content (items or message), auto-hide, event monitors
            StripViews: StripPanel (non-activating NSPanel), background (blur + hover tracking),
                        StripItemView (one clickable icon)
Settings/   SwiftUI settings (tabs: General, Keep Awake, Hidden Icons, Permissions, About+Diagnostics)
Support/    Preferences (UserDefaults, ObservableObject), HotKey (Carbon RegisterEventHotKey),
            KeyCombo, Permissions, ClosureMenuItem
```

Key flows:
- **Hide:** `StatusBarController.applyState()` sets the divider length to 10 000 when hiding, or 12 when revealed. `isOrderValid` refuses to hide if the divider isn't left of the chevron, because hiding would then push the chevron off-screen too. The ┃ is an `NSImageView` pinned to the divider button's **right edge**, so it stays next to the chevron even while stretched. Its visibility is `!isHidingItems || showsDividerWhileHidden`.
- **Reveal counting:** `beginTemporaryReveal`/`endTemporaryReveal` are ref-counted. Arrange mode (`isArranging`) also reveals.
- **Strip show:** the scan runs in `Task.detached` → `MenuBarScanner.hidden(items, dividerFrame:)`, which returns items whose `maxX <= divider.minX` on the same menu bar row. The strip is presented with cached images, then refreshed.
- **Image caching:** `AppDelegate.captureHiddenItems()` runs at launch **before** the first hide (0.6 s delay), when arranging ends (`onEndArrangingRequested`), and after each activation reveal (`activator.onItemsRevealed`).

## macOS findings that shaped the design (important)

1. **On macOS 26, every status-item window is owned by Control Center** in `CGWindowListCopyWindowInfo`, so the owner PID is useless. Item ownership comes from Accessibility: `AXUIElementCreateApplication(pid)` → `kAXExtrasMenuBarAttribute` → children. Window IDs (needed for capture) are matched by finding the status-level window (layer 25) that **contains the AX frame's centre**. AX frames can be narrower than windows, so don't match on exact x/width.
2. **ScreenCaptureKit can't capture off-screen status windows.** A capture while hidden returns 0 of 7; while visible it returns 7 of 7. That's why the image cache exists. `isBlank()` rejects fully transparent captures.
3. **The divider length is capped by the system** at about 5016 pt on this Mac, which is still enough.
4. **Notch:** new status items appear leftmost, which on a crowded notched menu bar is behind the notch (reported `onScreen=false`). `seedInitialPositions()` writes `NSStatusItem Preferred Position controlbar.*` = 0/1/2 on first launch, which puts ControlBar at the right end. Side effect: every other third-party icon starts out hidden. This was intentional and is documented in the README.
5. The system's own Control Center items (Wi-Fi, battery, clock) didn't appear in the AX scan. They're right of the divider anyway, but if a user moves one left of the divider it won't show in the strip. This is an open question.
6. Some items (e.g. TextInputMenuAgent "ABC") can end up between chevron and keep-awake. That's harmless.
7. The strip's appearance is set to the menu bar's `effectiveAppearance`, because captured glyphs are drawn for the menu bar (the user's is dark, with white glyphs). Monochrome captures are marked `isTemplate` and tinted with `labelColor`.

## Building, running, testing

```bash
cd ~/perch-temp
scripts/build.sh            # → build/ControlBar.app, signed with "Perch Local Signing"
pkill -x ControlBar; open build/ControlBar.app
```

- **Signing:** `scripts/make-signing-cert.sh` already created a self-signed identity called **"Perch Local Signing"** in the user's login keychain. It isn't trusted system-wide, but `codesign` accepts it. Its designated requirement is pinned to the leaf certificate, so **TCC grants persist across rebuilds**. Don't switch to ad-hoc signing, or the user will have to re-grant permissions.
- **Diagnostics mode** is the main way to verify behaviour without clicking:
  ```bash
  pkill -x ControlBar; sleep 1          # IMPORTANT: a running instance keeps icons hidden and skews results
  open -W -n build/ControlBar.app --args --diagnose /some/dir
  cat /some/dir/report.txt         # REVEALED and HIDDEN sections; PNGs in /some/dir/{revealed,hidden}/
  open build/ControlBar.app             # restart the normal instance afterwards
  ```
- Launch the app with `open`, not by running the binary directly. Otherwise TCC treats the calling process (Claude) as responsible and the permissions don't apply.
- **Limits of the agent environment:** `screencapture` fails ("could not create image from rect"), and the shell has no Accessibility permission, so you can't click status items or send keys. Ask the user to test anything interactive, or have them paste *Settings → About → Copy Diagnostics*.
- `swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`, which is already generated: a bird on a controlbar, orange gradient.
- Useful check: `pmset -g assertions | grep -i controlbar`.

## Likely next steps

1. **Act on the user's test feedback.** `ItemActivator` is the riskiest part. Things to look at if clicking an item from the strip misbehaves:
   - `waitUntilOnScreen` checks that the AX frame's centre is on any screen. It polls 30 × 40 ms, then waits 60 ms for layout to settle.
   - `waitForMenusToClose` treats any **new** on-screen window at layer ≥ 24 and < 1000 that isn't a menu-bar-height strip as "menu open". It waits up to 1.5 s for one to appear, then until they're all gone (10 min cap).
   - The strip is hidden before activation, and items are re-hidden via `endTemporaryReveal`.
2. Consider revealing only the clicked item, the way Ice moves a single item with synthetic ⌘-drags, instead of the whole hidden section. That's only worth doing if the user dislikes the flash.
3. The hotkey recorder: while recording, the currently registered Carbon hotkey still fires. Consider pausing it during recording.
4. Multi-display: the active menu bar can be on the Dell (y = -1080 in CG coordinates). The scanning and hidden filter handle this (same-row check with a 30 pt tolerance). The strip is anchored to `chevronWindow.screen` and hasn't been tested on the external display.
5. Rename from "ControlBar" / `net.controlfix.ControlBar` when the user picks a final name. Places to change: `Info.plist`, `Package.swift`, the scripts, the README, the autosave names `controlbar.*`, and the signing identity name.
6. Open-source polish once the user wants it: first commit, GitHub repo, CI build, a universal build (`UNIVERSAL=1`), and notarization (which needs a Developer ID; the local certificate is for development only).

## Memory
A project memory was saved (`controlbar-project`) covering location, constraints, the credit rule and the macOS 26 ownership quirk.
