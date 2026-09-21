# Cotto Linux UI

A compact native quick menu, modeled on upstream Sotto's 310px menu rather than
its large settings window. Dictation happens through shortcuts in other applications.

## Structure

Open to a small menu: app name and engine status, shortcut hint, Copy last message,
links to Dictionary / Microphone / Shortcuts / Engine, and Quit. Dictionary is one
screen, not the home screen. Settings replace the menu and offer a Menu back button;
there is no sidebar. Unsaved dictionary edits survive navigation.

Default size: 340 × 380. Minimum: 320 × 340. Pages scroll when needed. No cards,
repeated device information, large empty panels, or filler instructions.

Show recording controls and errors in a compact footer when relevant. The latest
transcript opens only on request for recovery and copying. Closing the window
hides it when a tray host is available, without cancelling dictation. Microphone
tests stop on hide. Tray Open and the app-menu launcher reopen the existing window.
Quit cancels an active take before exiting the client; inference stays running.
Without a tray host, Close quits rather than leaving an unreachable process.

## Tokens

- Main background: `#16121c`
- Navigation and secondary controls: `#2c1e28`
- Selected navigation and primary controls: `#5d2f38`
- Control borders and pressed state: `#985961`
- Supporting text: `#bd9daf`
- Primary text and keyboard focus: `#f2e8ed`
- Input surface: `#211722`
- Error text: `#f2cd91`
- Noto Sans; 14px body, 20px headings.
- Square corners on every button, field, and surface; no card shapes.
- Page margins: 16px; compact 10px content spacing.

Use standard Qt interactions. Keyboard focus must remain visible; duplicate
navigation and back navigation must work with both mouse and keyboard. No animation is needed.

## Dictionary

One word or phrase per line, an explicit Save, and inline validation. Words belong
to the Linux user and travel only with that user's takes. Never seed personal
project names into application defaults or server-wide preferences.
