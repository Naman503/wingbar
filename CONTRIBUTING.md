# Contributing

Thanks for your interest! Issues and pull requests are welcome.

## Setup

```bash
cd app
swift build && swift test
scripts/bundle.sh release && open build/Wingbar.app
```

Bundle with `SIGN_IDENTITY="Apple Development: …"` so macOS keeps the Accessibility grant between builds.

## Before opening a pull request

- `swift test` passes in `app/`.
- **Changes to discovery, moving or clicking:** try them on a notched MacBook with icons under the notch, with the hidden section both open and closed, and with a full-screen app in front (Wingbar must do nothing there). `spike/` has small commands (`list`, `capture`, `move`, `shot`) for checking what macOS reports.
- **Changes to preferences:** new fields in `WingPreferences` must decode from older saved settings (add the key to `init(from:)` with a default).

## Conventions

- **Pure logic belongs in `WingbarCore`, with a unit test**: geometry, matching, layout, ordering, preferences. The `Wingbar` target holds AppKit, Accessibility and ScreenCaptureKit glue.
- **Never post synthetic events without the safety checks** in `MoveEngine` (menu bar visible, user not using the mouse).
- **Comments explain *why*, not *what*.**

## Reporting bugs

Please include:
- the macOS version and Mac model (notch or not);
- what you expected and what happened;
- if icons are involved, the output of launching with `--dump-scan=/tmp/scan.txt` (it lists app names and menu bar titles, so check it before sharing).
