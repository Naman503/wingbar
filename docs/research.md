# Wingbar: Research & Plan

Working name: **Wingbar**. The notch splits the menu bar into two "wings", and the app puts your status items on both of them.

Researched 2026-10-26 on a 14" MacBook Pro (M4), macOS 26.6.1 (Tahoe), Xcode 26.2. This is the original research and plan; the [README](../README.md) describes what was built.

---

## 1. The problem, measured

`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` report this for a built-in display (1800×1169 pt at the current scaling):

```
x=0                         790        1010                        1800
|  App menus | FREE SPACE   | ■ NOTCH ■ |  status items ... ⌃ 🔋 🕘  |
|<------ left wing 790pt -->|<-220pt -->|<------ right wing 790pt -->|
```

* Status items (`NSStatusItem`) only ever live in the **right wing**. macOS fills it from right to left (Control Center and the clock first, then the newest items).
* When the next item would land under the notch, or would collide with the frontmost app's menus, macOS **doesn't move it anywhere. It just doesn't draw it.** No API reports this: `NSStatusItem.isVisible` still returns `true` for an item hidden by the notch.
* Meanwhile the **left wing usually has 250–450 pt of empty space** between the end of the app menus (File, Edit, View…) and the notch. That space is wasted.

**Your idea, restated:** when the right wing is full, keep going on the other side of the notch, in the free part of the left wing, and make the notch itself useful.

## 2. Can macOS do this natively?

No. You can't move a real status item to the left of the notch, because WindowServer owns that layout. Every existing product works around it in one of three ways:

| Approach | Used by | Result |
|---|---|---|
| Hide items behind a divider, reveal on click | Hidden Bar, Dozer, Vanilla | Simple, but still limited by the notch: revealed items can get swallowed again |
| Show hidden items in a **separate floating bar** under the menu bar | Bartender 6 ("Bartender Bar"), Ice/Thaw ("Ice/Thaw Bar"), Tuck ("Shelf mode") | Works with the notch, but it's a second strip below the bar, not *in* the bar |
| Use the notch as a widget surface | boring.notch, NotchNook | Nice widgets, but doesn't manage menu bar items |

**Nobody puts overflow items into the free left-wing space next to the notch, and nobody combines a menu bar manager with a notch hub.** That's the gap Wingbar fills.

Free things you can do today, before any app exists:

1. **Tighten spacing.** Undocumented defaults; the default spacing is about 16. Lower values fit roughly 30–40% more icons:
   ```bash
   defaults -currentHost write -globalDomain NSStatusItemSpacing -int 8
   ```
   ```bash
   defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 6
   ```
   Then log out and back in. To undo, run `defaults -currentHost delete -globalDomain` with each key name.
2. **Remove what you don't need.** On Tahoe, go to System Settings → Menu Bar → *Allow in the Menu Bar*.

Wingbar should also expose the spacing setting in its UI. Thaw does this in `MenuBarItemSpacingManager.swift`.

## 3. How menu bar managers really work

I read the source of **Thaw** (github.com/kr11/Thaw, forked from thaw-app/Thaw). It's the actively maintained GPL-3.0 fork of Ice and supports macOS 26/27. Here is the actual mechanism:

| Job | Technique | API / permission |
|---|---|---|
| **Find all items** | Enumerate the menu-bar-level windows via the private CoreGraphics/SkyLight window list (`CGSGetWindowList`, `CGSGetOnScreenWindowList`, `CGSCopySpacesForWindows`). On Tahoe the window owner is no longer the source app, so Thaw runs a separate **XPC helper (`MenuBarItemService`)** that maps each item back to its app through the app's Accessibility "extras menu bar" | Private CGS (no permission needed), Accessibility |
| **Hide items** | Your own `NSStatusItem` acting as a **divider**. Set its `length` to 10000 pt and every item to its left is pushed off-screen. Set it back to `variableLength` to reveal them | Public API, no permission |
| **Reorder items** | Synthesized **⌘-drag mouse events** (`CGEvent` posted to the window server), the same thing you do by hand with ⌘-drag | Accessibility |
| **Show an item's icon elsewhere** | Capture its window image with **ScreenCaptureKit** (`SCScreenshotManager.captureImage`) or a SkyLight private capture call, then draw that bitmap in your own panel | Screen Recording (optional) |
| **Click a hidden item** | `temporarilyShow`: briefly move the real item into the visible area, synthesize a click so its menu opens in the right place, then move it back after the menu closes. Fast path: `AXPress` on its accessibility element (`AXItemActivator.swift`) | Accessibility |
| **Hide app menus to make room** | Temporarily activate itself, so the bar shows only the manager's tiny menu | Public |

Takeaways:

* **The icons in any "overflow bar" are pictures**, and a click has to reach the real item. That's the hard, fragile part: `MenuBarItemManager.swift` alone is about 9,300 lines.
* **Every macOS release breaks these apps.** Ice's stable version broke on Tahoe ("Unable to display menu bar items"), which is why Thaw exists. Expect a week of fixes after each major macOS update.
* **No Mac App Store.** Private APIs and posting events to other apps aren't allowed there. Distribute as a notarized DMG on GitHub Releases. Without a $99/yr Developer ID, users get the "unidentified developer" prompt, the same as boring.notch today.

## 4. Proposed design

### 4.1 Three surfaces

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Finder File Edit View │ [Left Wing: overflow ▸▸▸] │■NOTCH■│ [right wing] ⌃🔋🕘 │
└──────────────────────────────────────────────────────────────────────────────┘
                                          ┌──── Notch Hub (hover / click) ──────┐
                                          │ all hidden items grid · search      │
                                          │ widgets: media · calendar · shelf   │
                                          └─────────────────────────────────────┘
```

1. **Right wing (native).** Items you pin as "always visible" stay as real items.
2. **Left Wing (new idea).** A borderless, non-activating `NSPanel` at menu-bar window level, placed exactly in the free space between the app's last menu and the notch's left edge. It draws captured images of the overflow items at native size and spacing, so it looks like part of the menu bar.
   * Width = `notch.minX − appMenus.maxX − margin`. `appMenus.maxX` comes from the frontmost app's `kAXMenuBarAttribute` children frames.
   * Recalculate on `NSWorkspace.didActivateApplicationNotification`, on AX menu-change notifications, and on screen changes. If an app has many menus (Xcode, Office), the wing shrinks and the rest spills into the Notch Hub.
   * Clicking an icon goes through `AXPress` first, falling back to temporarily showing the real item.
   * Optional "Focus" toggle: hide app menus to give the Left Wing the whole left side.
3. **Notch Hub.** Hover or click on the notch rect and a Dynamic-Island-style panel expands down from it: a grid of every hidden item, search (⌘-key), and widgets.

On an external display with no notch, the Left Wing turns off and overflow goes to the hub or a dropdown under a chevron.

### 4.2 Tech stack (lightweight by design)

* **Swift 6 + AppKit** for the panels and status items, **SwiftUI** for Settings and the hub content. No Electron or web views, so expect about 30–60 MB RAM and near-zero idle CPU.
* `LSUIElement` agent app (no Dock icon), launch at login via `SMAppService`.
* Event-driven, not polling: re-scan only on app-activation, screen, space and AX notifications.
* Small XPC helper for item to app mapping (same pattern as Thaw), so a hung app can't freeze the UI.
* Minimum macOS 14. Primary target 26 (Tahoe). Liquid Glass material on 26.

### 4.3 Permissions (asked progressively, never all at once)

| Permission | Needed for | Without it |
|---|---|---|
| Accessibility | Moving items, clicking hidden items, measuring app menus | Divider hide/show only |
| Screen Recording | Drawing item icons in the Left Wing and hub | Hub shows app names/icons instead of the live item image |

## 5. Feature list

**MVP (v0.1): solves the core problem**
- Divider-based sections: Visible / Overflow / Always hidden
- **Left Wing** overflow next to the notch, with auto-resize as app menus change
- Notch Hub with a grid of overflow items, click to open
- Drag to arrange items in Settings
- Spacing slider (writes the two defaults keys and restarts the menu bar)
- Launch at login, global hotkey to open the hub

**v0.2: polish**
- Search any item from the keyboard (type to filter, Enter to open)
- Per-app rules: e.g. when Xcode is frontmost, push more items to the hub
- Profiles: Work / Presenting / Battery, switchable by hotkey, Focus mode or display connected
- Auto-show an item when it changes (e.g. a recording dot or a badge appearing)
- "Focus" mode that hides app menus for maximum Left Wing room
- Multi-display awareness (notch vs no-notch screens)

**v0.3: make the notch useful (the "customize that area" part)**
- Now Playing with controls (MediaRemote), plus a small visualizer
- Next calendar event and a countdown (EventKit)
- File shelf: drop files on the notch, drag them out later (AirDrop / share)
- Clipboard history peek
- Live activity slots: timer/pomodoro, download/build progress, battery-low, mic/camera-in-use indicator
- Custom HUD replacing the volume/brightness overlay
- Menu bar tint, borders and rounded "island" shapes, separately for light and dark

**Later / integrations**
- `wingbar://` URL scheme, Shortcuts actions, Raycast extension
- Plugin widgets (simple JSON + script widgets, like SwiftBar/xbar) shown in the hub

## 6. Build plan

| Phase | Goal | Done when |
|---|---|---|
| **0. Spike** ✅ done 2026-10-26, see [spike/FINDINGS.md](../spike/FINDINGS.md) | Prove the risky parts on macOS 26.6.1: (a) enumerate all item windows and map them to apps, (b) capture their images, (c) open a hidden item's menu via `AXPress` or temporary move | Discovery ✅ (public APIs only), capture ✅ (incl. under notch), activation ⚠️ AXPress works for standard menus; others need reveal + real click |
| **1. Skeleton** ✅ done 2026-10-26 | Agent app, divider sections, permission onboarding, settings window | Hide/show works; Items tab lists every item by section; right-click opens hidden items via AXPress |
| **2. Left Wing** 🚧 working 2026-10-26 | Geometry service, app-menu measurement, overflow panel, click forwarding | Overflow icons appear left of the notch and open their menus |
| **3. Notch Hub** | Hover detection on the notch rect, expanding panel, grid and search | All hidden items reachable from the notch |
| **4. Polish & ship** | Spacing, profiles, rules, login item, CI, notarized DMG, GitHub Release | v0.1.0 release in Naman503/wingbar |
| **5. Widgets** | v0.3 feature set | — |

**Decision gate after Phase 0:** if item discovery or click forwarding turns out too brittle on Tahoe, **fork Thaw instead** and add the Left Wing and Notch Hub on top. You get its battle-tested item engine. The cost is that Wingbar must then be GPL-3.0 and inherits a much heavier codebase. Writing our own lean engine but borrowing ideas (not code) keeps any license open.

## 7. Risks

| Risk | Mitigation |
|---|---|
| macOS updates break private APIs | Isolate them behind one `Bridging` layer; test each macOS beta; keep a fallback mode that only uses the divider and the hub |
| Left Wing overlapping app menus or other overlays | Re-measure on every activation and menu change, leave a safety margin, auto-collapse into the hub |
| Fullscreen apps / auto-hidden menu bar | Hide the panels when the menu bar hides (observe `NSApplication` presentation options) |
| Captured icon goes stale (e.g. a timer item) | Re-capture on window-change events while visible; cache otherwise |
| No notarization (no Developer ID) | Document the quarantine workaround, ship via a Homebrew cask that handles it |

## Sources

- Thaw source: https://github.com/kr11/Thaw (files: `Shared/Bridging/*`, `Thaw/MenuBar/ControlItem/ControlItem.swift`, `Thaw/MenuBar/MenuBarItems/MenuBarItemManager.swift`, `Thaw/MenuBar/IceBar/IceBar.swift`, `MenuBarItemService/`)
- Ice on Tahoe: https://github.com/jordanbaird/Ice/discussions/672 · https://github.com/jordanbaird/Ice/issues/679
- Bartender alternatives roundup: https://www.macstories.net/roundups/managing-your-mac-menu-bar-a-roundup-of-my-favorite-bartender-alternatives/
- Spacing defaults: https://9to5mac.com/2026/05/22/how-to-stop-menu-bar-items-being-hidden-behind-the-macbook-pro-notch/ · https://www.jessesquires.com/blog/2023/12/16/macbook-notch-and-menu-bar-fixes/
- boring.notch: https://github.com/TheBoredTeam/boring.notch
- Tahoe "Allow in the Menu Bar": https://appleinsider.com/inside/macos-tahoe/tips/inside-control-center-on-macos-tahoe
