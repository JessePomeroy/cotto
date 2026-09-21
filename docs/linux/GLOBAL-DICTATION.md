# Global dictation

Global dictation uses KDE shortcuts and ordinary clipboard paste into the
currently focused application. It does not discover Herdr panes, inspect editor
contents, or prove which field will receive text.

## Shortcuts and permission

Start the client with `--global-dictation` only when ready to approve KDE's
keyboard-only portal permission and shortcut setup. The proposed defaults are:

| Action | Preferred shortcut |
| --- | --- |
| Hold to dictate | Meta + grave |
| Start/stop toggle | Meta + Alt + D |
| Cancel | Meta + apostrophe |

These are configurable defaults, not mandatory system bindings. Resolve conflicts
in KDE rather than silently replacing compositor shortcuts. The Shortcuts screen
shows the bindings actually granted by the portal. Permission is session-only and
may need approval after a client restart.

## Delivery

1. Focus the intended input before recording.
2. Hold/release the shortcut or use the toggle; keep the destination focused.
3. Release modifier keys while local inference finishes.
4. Cotto validates the transcript, stages it with an owned `wl-copy` process,
   verifies it with `wl-paste`, then dispatches Ctrl+Shift+V once.
5. Treat the outcome as **unconfirmed paste** and inspect the destination.

Cotto does not send Enter, submit forms, synthesize arbitrary text as keystrokes,
or automatically retry. Unsafe/control-character text is blocked. Clipboard
ownership changes, cancellation, lock, and other guard failures stop delivery.
Clipboard restoration is guarded so a newer owner is not overwritten.

A changed focus can still change the destination: keyboard permission is not a
field-identity guarantee. If delivery is uncertain, use Review message or Copy
last message explicitly, after checking whether the text already arrived.

## Recording feedback

While global dictation captures, enabled Pi sessions can observe the private
recording signal and show `●`; idle shows `○`. This indicates Cotto is recording,
not which Pi pane or application is the destination. Microphone tests do not
publish global recording status.

## Scope

Pi's Ctrl+Shift+R uses a different, editor-owned path. It never falls back to
current-focus global paste. See [Pi integration](PI-OWNED-DICTATION.md).

Private-D-Bus and clipboard fixtures verify adapter behavior without granting real
desktop permissions. Physical modifier timing, destination changes, lock/suspend,
and unplug/reconnect still require desktop acceptance; see [testing](TESTING.md).
