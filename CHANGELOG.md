# Changelog

## Unreleased

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
