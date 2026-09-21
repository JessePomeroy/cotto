# Tray, startup, and recovery

The native client and inference server are independent **user services**:

- `cotto.service` runs the desktop with global and Pi-owned dictation enabled.
- `cotto-inference.service` runs the loopback inference server and native helpers.

The client wants the inference service, but quitting the client does not stop it.
Both belong to the graphical session and have bounded restart-on-failure behavior.

## Window lifecycle

Close hides Cotto when a tray host is available. Active dictation continues;
a microphone test stops. Click the tray icon, choose Open cotto, or launch the
application menu entry to reopen the same window. Unsaved dictionary edits remain.
Without a tray host, Close quits rather than leaving an unreachable process.

Quit cotto cancels an active take, waits for the controller to settle, and exits
normally. Systemd does not restart a normal Quit. Inference stays running. The
application launcher's explicit **Quit cotto and stop inference** action stops both.

Desktop activation exports only `org.sotto.Sotto.Show` at `/org/sotto/Sotto` on the
user-session name `org.sotto.Sotto.Dev`. The launcher starts the service, waits for
that name, and calls Show. The endpoint cannot start recording or quit the client.
Qt Widgets supplies the tray implementation.

## Configure and install

Build the [desktop](../../Linux/README.md) and [server](../../Server/README.md) first.
Review generated units before installation: these are checkout-based development
units, not a relocatable desktop package.

- `build/linux/cotto.service` selects the client binary and `XDG_CONFIG_HOME`.
- `build/linux/cotto-inference.service` selects port 8392, helper/model paths, and
  the `.local/validation-server` data directory under the checkout. Choose the
  intended archive explicitly; do not accidentally replace an existing profile.
- The inference template includes a partial-GPU development profile. Review
  `SOTTO_TEXT_GPU_LAYERS` and `SOTTO_TEXT_KV_TYPE` for your hardware; use zero GPU
  layers for CPU operation.

`COTTO_QT_CONFIG_HOME` is a CMake cache setting, defaulting to `~/.config`. A custom
value selects a distinct Qt profile, including its personal dictionary. Always
use the service's configured profile when importing or editing words.

After reviewing paths and choosing to install:

```zsh
cmake --install build/linux --component cotto-startup --prefix "$HOME/.local"
systemctl --user daemon-reload
systemctl --user start cotto.service
```

Installation alone does **not** enable login startup. Enable it only if wanted:

```zsh
systemctl --user enable cotto.service
```

No recording starts at login. KDE keyboard permission remains session-only:
approve it again after a client restart if prompted. Without permission, automatic
global paste remains unavailable. Pi-owned dictation is a separate explicit route.
An offline or busy server does not open the microphone or queue a later take.

## Operate

```zsh
systemctl --user status cotto.service cotto-inference.service
systemctl --user show cotto.service cotto-inference.service -p MainPID -p NRestarts

# Restart only while dictation is idle; permission may need approval again.
systemctl --user restart cotto.service

# Stop both and disable future client startup.
systemctl --user disable --now cotto.service
systemctl --user stop cotto-inference.service
```

Do not run unmanaged launch commands alongside the user service. Repeated
application-menu launches reuse the managed instance. The Pi listener uses a lock
and conservative stale-socket recovery; it preserves live listeners, regular files,
and symlinks rather than deleting them to force startup.

After updating Pi integration code, run `/reload` in each existing Pi session.
Protocol v2 deliberately rejects older clients before capture. This does not
change the independent v1 recording-status file.

Fresh-login, physical shortcut, lock/suspend, and device-loss checks remain separate
acceptance work; see [status](STATUS.md).
