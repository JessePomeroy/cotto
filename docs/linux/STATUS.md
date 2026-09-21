# Status and remaining work

cotto is Linux-only development software, targeting KDE Plasma on Wayland.
The repository preserves Sotto's license and compatibility identifiers, not its
macOS application or Swift build paths.

## Implemented

- Compact 340 × 380 menu, separate settings screens, square controls, keyboard
  navigation, and transcript recovery.
- Per-user dictionary with validated atomic saves and isolated per-take hints.
- Input/channel selection, microphone metering, streaming conversion, bounded
  capture, sequenced uploads, cancellation, and local inference.
- KDE global shortcuts and permissioned, single-attempt focused-app paste.
- Pi-owned editor/question insertion with identity and draft guards; protocol-v2
  one-use IDs remove the former lifetime take limit without evicting replay safety.
- Read-only global recording feedback in Pi's circle.
- Native tray, hide-on-close, explicit cancel-before-quit, and application-menu
  reopen without restarting inference.
- Opt-in systemd user startup, private socket recovery, and provider-free test gates.

## Verification boundaries

Automated tests cover native UI interactions at default/minimum sizes, conversion
and transport rules, dictionary isolation, Pi replay/ownership, desktop adapters,
tray actions, and server/helper failure handling. A 4,101-take regression verifies
long-running Pi admission. The installed-Pi probe has been exercised against the
real editor adapter without submission.

Live KDE tray registration, normal tray Quit, application-menu reopen, and
independent inference lifetime have been checked locally. These are not substitutes
for physical keyboard, acoustic, lock/suspend, or login acceptance. Build and test
commands are in [TESTING.md](TESTING.md); CI is Linux-only.

## Next acceptance checks

When a user is available at the desktop:

- Verify hold/toggle/cancel shortcuts and keyboard permission after restart.
- Reload Pi and confirm both its owned recording and global recording indicator.
- Check real recognition of personal words; hints do not guarantee spelling.
- Exercise lock, suspend, microphone unplug/reconnect, and fresh-login startup.
- Check plain-shell paste and destination changes without accidental submission.

## Later, not implied by the current scope

- History/deletion and retention controls in the compact native UI.
- Reproducible Arch desktop packaging, then AppImage.
- Additional compositors and optional cleanup improvements only with explicit
  requirements and acceptance evidence.

Global paste remains unconfirmed current-focus dispatch, not authenticated
field-level insertion. No automatic Enter, submission, or uncertain-delivery retry
is implemented. Neither the server nor the dictionary adds per-account history
isolation. See [architecture](../architecture.md) for the exact boundaries.
