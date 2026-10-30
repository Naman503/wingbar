# Changelog

## Unreleased

## 0.2.1: 2026-10-31

Arranging now works the way you'd expect: drag icons into the order you want, press **Apply**, and Wingbar moves the real icons in one pass, around any app that refuses to be moved. Scanning is also about 20× faster.

### Changed
- **Arrange, then Apply.** Dragging rows only edits a draft; *Apply* moves the real icons in one pass (with *Revert* to discard). The plan covers both sides of the line at once and moves as few icons as possible.
- **Icons that ignore moves** (e.g. Cloudflare WARP) are detected, tagged "Won't move", remembered, and the other icons are arranged around them. The Left Wing explains instead of trying to move them into view.

### Fixed
- **Arranging moves the real icons, always.** A move planner keeps the longest run of icons already in order and moves only the rest, each next to a neighbour whose edge is visible (so "Slack before WARP" becomes one move: WARP right of Slack). When both neighbours are under the notch, it rebuilds the rest of the order next to Wingbar's line instead of silently changing only the list.
- Both Arrange lists always show the real menu bar order; icons with no room at all are pinned at the top and can't be dragged. Each hidden row shows where it is now: in the menu bar, in the Left Wing, or no room.
- The menu bar list no longer empties while the screen is locked or a full-screen app is in front.
- Moves next to the notch are no longer reported as failed while macOS is still settling them; Apply judges by the final order.
- The menu bar counts as hidden when no icon is drawn (full-screen apps report the menu bar window anyway), so nothing moves then.
- Scanning is about 20× faster (3.5 s → 0.16 s first scan, ~13 ms after): apps are asked in parallel, and apps without menu bar icons are re-checked only every 30 s.
- Launch at login follows the app if it moves (e.g. into Applications); new `--launch-at-login` flag.

## 0.2.0: 2026-10-26

The first public release. Icons your MacBook's notch hides now appear in the free space on the other side of it, the **Left Wing**, looking and working like the real ones, and you can arrange both sides by drag and drop.

### Added
- **Left Wing:** icons macOS hides under the notch (or can't fit at all, or that sit behind Wingbar's closed line) appear in the free menu bar space left of the notch, as pictures of the real icons. It re-fits as the front app's menus change and hides over full-screen apps.
- **Opening hidden icons:** a native copy of the icon's menu under its Left Wing icon (read and pressed through Accessibility); an Accessibility press for popover apps; and a **move engine** that ⌘-drags icons which only open from their own icon into view, clicks them, and puts them back in their exact slot.
- **Arrange tab:** drag-and-drop lists of both sides that mirror the real menu bar; drop between them to show or hide an icon.
- **Customization:** icon size, spacing, position, order, gap after the app's menus, background, fallback icon style, shown always or on hover, overflow bar or list, optional notch hover, groups, per-icon rules, global shortcut, Wingbar icon style, scan frequency, and Left Wing mode.
- **Icon pictures:** capture once and reuse from disk (default), live, or off, with per-icon live pictures.
- **Spacing "Apply Now":** relaunches menu bar apps (after asking) so new spacing applies without logging out.
- App icon, main menu (⌘, ⌘Q ⌘W, copy/paste), click Wingbar's line to open or close Settings, Settings closes on a click elsewhere.

### Fixed
- Item matching survives the moment after the menu bar re-lays out, when window frames still report old positions.
- Item identities no longer include live titles such as "47%", so rules and groups stick.

## 0.1.0: 2026-10-26

### Added
- Menu bar sections with a divider: click the Wingbar icon to show or hide icons left of the line; optional always-hidden section; auto-hide.
- Right-click menu listing every icon not currently drawn, opened through Accessibility.
- Permission onboarding; Settings with General, Items, Spacing, Permissions and About.
- Phase 0 spike proving discovery, capture and activation on macOS 26 (`spike/`).
