# Phase 0 spike: findings

Run on 2026-10-26: MacBook Pro M4, macOS 26.6.1, notch at x 790–1010 pt, 19 status items.
Code: `Spike.swift` (throwaway). Build with `./build.sh`, then run:

```bash
open -W -n build/WingbarSpike.app --args list --out=$PWD/out
```

Commands: `prompt`, `list`, `capture`, `press <name|index>`, `click <name>`. Logs and PNGs go to `out/`.
The app is signed with the Apple Development identity, so the Accessibility and Screen Recording grants survive rebuilds.

## Verdict

| Goal | Result |
|---|---|
| 1. List every item and map it to its app | ✅ **Works, with public APIs only** |
| 2. Capture item images | ✅ for every item that has a window, **including ones under the notch**. ❌ for "parked" items (no window) |
| 3. Open a hidden item's menu | ⚠️ **Partial.** AXPress works for apps with standard menus, even when hidden. Control Centre items and custom-click apps need a real click at a visible spot |

**Decision gate:** writing our own lean engine is viable, so there's no need to fork Thaw. The one hard piece left is the "reveal, then real click" fallback.

## What we learned

### Discovery
* On Tahoe, **every status item window is owned by Control Centre (pid 662)**, whatever app it belongs to. `kCGWindowName` is empty without Screen Recording. So the window list alone can't tell you which app an item belongs to.
* `CGWindowListCopyWindowInfo` filtered to layer 25 with y = 0 gives every on-bar item with its frame and `isOnscreen`. This needs **no permission**.
* Mapping to apps: walk every running app's `AXExtrasMenuBar` children (needs Accessibility). The AX frame is the *icon*, inset a few points inside the window, so **match by containment, not exact x**. All 16 on-bar items matched, including Apple's own (identifiers like `com.apple.menuextra.wifi`).
* macOS hides overflow in **two different ways**:
  * **Under the notch:** the window exists at y = 0 with `isOnscreen = false` (Ledge, Cloudflare WARP, Tailscale).
  * **Parked:** no window on the bar at all. The AX frame sits off-screen at the bottom-left, y≈1168 (Cursor, ChatGPT, Claude). These items are invisible to the window list and only discoverable through AX.
* Thaw needs private CGS calls and an XPC helper for this. We didn't need either, so far. Keep a fallback in mind for apps with slow AX (one item returned `-25204`, a timeout, at 0.25 s).

### Capture
* `SCScreenshotManager.captureImage` with `SCContentFilter(desktopIndependentWindow:)` gives crisp 2× images. **It captures items hidden under the notch** (see `out/contact-sheet.png`: the first three icons are the hidden ones).
* Parked items have no window, so there's nothing to capture. Fallback: show the app icon (`NSRunningApplication.icon`), or reveal the item once and cache its image.
* Screen Recording only took effect after the app was explicitly listed and toggled in Settings. `CGPreflightScreenCaptureAccess()` kept returning `false` even after it worked, so **don't trust preflight on Tahoe; just try the capture.**

### Activation (opening the menu)
| Item | State | AXPress | Synthetic click via `postToPid` |
|---|---|---|---|
| Ledge | under notch | ✅ menu opened at x 727, y 46 (centered below the notch) | — |
| ChatGPT | parked | ✅ menu opened, but in the top-left corner (x −4) (AX reported `-25204`, yet it worked) | — |
| Cloudflare WARP | under notch | ❌ "success", nothing opens | ❌ (to the app or Control Centre) |
| Bluetooth (Apple) | visible | ❌ "success", nothing opens | ❌ |

* **AXPress returns success even when nothing happens.** Detect the outcome by diffing on-screen window IDs at layer ≥ 25 for about 800 ms. The opened menu showed up at layer 101, owned by the app.
* **Per-process synthetic clicks don't work on Tahoe**, even for visible items. Items like WARP and Control Centre modules need a **real HID click at an on-screen location**. So the item must be revealed first, which is Thaw's `temporarilyShow` approach.
* A menu opens wherever its item really is. For parked items that's the screen corner, which is another reason to reveal the item before opening it.

## Consequences for the design

1. **Activation pipeline:** AXPress → watch for a new window for about 800 ms → if none appears, **reveal the item temporarily** (make room in the right wing by collapsing other items through the divider, Bartender-style, or ⌘-drag it there the way Thaw does), send a real HID click, and restore when the menu closes.
2. **Left Wing images:** live captures for items under the notch; app icon or a cached image for parked items.
3. **Discovery needs no private APIs.** Keep the `Bridging` layer anyway for when a later macOS release breaks this.
4. Next spike (part of Phase 2): prototype the "reveal and click" fallback. It briefly moves your cursor and rearranges the bar, so run it as a deliberate test.

## Phase 2 additions: menus and moving (2026-10-26)

* **Menus are readable while closed.** Status items with a standard menu expose it as an `AXMenu` child, with titles, enabled state, ✓ marks, shortcuts and submenus (Tailscale, PiP Anywhere, TypePilot, ChatGPT). **Pressing an `AXMenuItem` while the menu is closed runs its action.** Wingbar uses this to show a native copy of the menu under the Left Wing icon.
* **Popover apps** (Claude Account Switcher, Stats, Weather, WARP) have no `AXMenu`, and some ignore `AXPress`.
* **Moving an item** (a synthetic ⌘-drag) works, with no drag events needed:
  * Mouse-down with `.maskCommand`, stamped with the *moving* item's window ID (`mouseEventWindowUnderMousePointer`, `…ThatCanHandleThisEvent`, raw field `0x33`) and `eventTargetUnixProcessID` set to the owning app.
  * Mouse-up (sent twice), stamped with the *target* item's window ID.
  * Both events go to the same drop point (target's `maxX` for "right of", `minX` for "left of"; y = 0).
  * Each event is posted to `.cgSessionEventTap` **and** `postToPid(appPID)`, from a `.hidSystemState` source with local-event suppression disabled. Thaw's tap handshake wasn't needed.
* **Drop points under the notch land in the wrong slot.** Only drop at visible points: right of Wingbar's divider (whose right edge is always on screen) to move an item in; left of its original right neighbour (or right of its left one) to move it back; else left of the expanded divider.
* Verified end to end: Claude Account Switcher moved from under the notch into view, its popover opened from the synthetic click, and it returned to its exact slot after closing.
* **Danger:** synthetic clicks at y≈0 while the menu bar is hidden (a full-screen app) land in that app. The engine checks that the menu bar is visible and that the user isn't using the mouse before posting anything.
