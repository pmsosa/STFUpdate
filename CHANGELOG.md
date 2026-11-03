# Changelog

## 1.0.2 (2026-11-03)

- Renamed the tool to STFUpdate: script, app bundle, launchd label, and config/state paths all moved
  from `update-or-stfu` to `stfupdate` (pre-1.0 `com.user.*` label migration is unaffected).
- README: badges, refreshed banner.

## 1.0.1 (2026-10-31)

- Fix: upgrading from the pre-1.0 install (old `com.user.*` agents) left the app showing PAUSED, because
  first-run setup only ran when no config existed. The app now loads the scheduler under the current label
  whenever it is missing, and retires the old agents.
- Settings: "Open Update or STFU at login" toggle (DMG build).
- Test for the label migration.
- CI on macOS: tests plus a build of the DMG.

## 1.0.0

- First release: scheduled Homebrew upgrades with a thaw period, menu bar app, drag-to-Applications DMG
  (Developer ID signed and notarized), tests, `build-dmg.sh`.
