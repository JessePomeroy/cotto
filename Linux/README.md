# Linux desktop

cotto is a native C++20/Qt 6 application for KDE Plasma on Wayland. Its 340 × 380
quick menu opens Dictionary, Microphone, Shortcuts, and Engine. Buttons and fields
have square corners; settings share the small window rather than a sidebar.

## Build

Requirements: CMake 3.24+, C++20 compiler, pkg-config, Qt 6.8+ (Core, Gui, Quick,
QuickControls2, Multimedia, Network, DBus, Widgets), and libsamplerate 0.2.2+.
Tests additionally use Qt Test/QuickTest, D-Bus, and Bun 1.4.2. Runtime global paste
requires `wl-copy`/`wl-paste` from wl-clipboard and KDE's desktop portals.

On Arch/CachyOS, install the dependencies you need explicitly:

```zsh
sudo pacman -S --needed base-devel cmake ninja pkgconf qt6-base qt6-declarative qt6-multimedia libsamplerate dbus wl-clipboard noto-fonts
bun install --frozen-lockfile
cmake -S Linux -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/linux
scripts/run_test_gates.sh fast
scripts/run_test_gates.sh subsystem desktop
```

Bun is development tooling for the server/tests, not a browser-based desktop UI.
No Swift or Xcode installation is needed. See [server setup](../Server/README.md)
for native helpers, model files, and the independently running inference service.

## Run

With the server listening on the selected loopback port:

```zsh
./build/linux/sotto-linux --server http://127.0.0.1:8392
```

This opens settings without requesting desktop keyboard permission. The
Microphone screen provides a bounded ten-second input test; it does not insert
text. Recording normally starts through global or Pi-owned shortcuts.

Enable integration explicitly when ready to approve KDE's permission dialog:

```zsh
./build/linux/sotto-linux --global-dictation --pi-dictation
```

Do not run an unmanaged instance alongside the managed user service. Each Pi
socket and desktop activation name has one owner. Use the application menu or
tray to reopen an existing managed instance.

Useful inspection commands do not open the microphone:

```zsh
./build/linux/sotto-linux --list-inputs
./build/linux/sotto-linux --desktop-capabilities
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./build/linux/sotto-linux --screenshot /tmp/cotto-menu.png
```

Screenshot mode does not request portal permissions, publish recording status,
register the tray, or open the Pi socket. It is a layout preview, not live desktop
acceptance evidence.

## Dictionary and recovery

Dictionary saves one word or phrase per line to
`$XDG_CONFIG_HOME/Sotto/Sotto Linux Dev/dictionary.json` (normally under `~/.config`).
Saves are validated, atomic, and owner-only. A service with a custom
`XDG_CONFIG_HOME` uses that profile, not the shell's default profile.

Each take snapshots these words without changing shared server preferences.
An empty personal dictionary remains empty. The server retains the snapshot in
that generation's archive; this is not an account-level privacy boundary on a
shared server. Cotto ships no user's project names as defaults.

Copy last message and Review message provide explicit recovery. Check the
intended destination before copying or pasting again: global paste is not
confirmed insertion and is never automatically retried.

## Tray and startup

Close hides the window while a tray host is available; active dictation continues,
but a microphone test stops. Tray Open and the application menu reopen the same
window. Quit cancels an active take before exiting the client and leaves inference
running. Without a tray host, Close quits instead of stranding the app.

Login startup and portal permission are separate choices. Installation does not
enable startup, and keyboard permission remains session-only. See
[startup and recovery](../docs/linux/STARTUP.md).

## Integration guides

- [Global shortcuts and paste](../docs/linux/GLOBAL-DICTATION.md)
- [Pi-owned dictation and recording indicator](../docs/linux/PI-OWNED-DICTATION.md)
- [Architecture and trust boundaries](../docs/architecture.md)
- [Test gates](../docs/linux/TESTING.md)
- [Supported behavior and remaining work](../docs/linux/STATUS.md)
