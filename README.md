# Pi TV

Send a YouTube link or a local video from your phone or laptop and it plays
fullscreen on the TV attached to a Raspberry Pi. Home network only.

* **Server** (`apps/server`): Dart HTTP + WebSocket server on the Pi
  (Raspberry Pi 4, Debian 13 Trixie, aarch64). YouTube plays in the system
  **Chromium** driven over the DevTools Protocol (normal window with its own
  profile, not kiosk); local files play in **mpv**. Queue, now playing,
  history, PIN login, HDMI-CEC, screen-blank inhibit. Wayland (labwc) first,
  X11 fallback, detected at runtime.
* **Remote** (`apps/remote`): one Flutter UI built for **Android** (share
  target for YouTube links) and the **web** (served by the Pi at `/`).
* **Shared** (`packages/pi_tv_shared`): models, API client, YouTube URL
  parser, PIN helpers — used by both.

```
pi-tv/
  packages/pi_tv_shared/   models, API client, YouTube URL parser, PIN/lockout
  apps/server/             Dart server (bin/pi_tv_server.dart), AOT for linux-arm64
  apps/remote/             Flutter remote -> Android APK + web
  deploy/                  systemd units, example config, install.sh for the Pi
  docs/                    INSTALL.md (Pi setup), DESIGN.md (behaviour, API, testing)
  tool/                    check.sh, build-*.sh, package-release.sh
```

The repo is a plain Dart multi-package workspace: each package has its own
`pubspec.yaml` and the apps depend on `pi_tv_shared` by path. (A single pub
workspace is avoided on purpose: the server must resolve and AOT-compile in a
Dart-only arm64 container without the Flutter SDK.) `tool/check.sh` runs
everything.

## Quick start (development)

Requirements: Dart ≥ 3.6 / Flutter ≥ 3.27 (built with Flutter 3.47.8 / Dart 3.13.7).

```sh
tool/check.sh                       # format, analyze and test all three packages

# run the server against this machine's desktop (Wayland or X11)
cd apps/server
TV_PIN=012345 MEDIA_DIRS=$HOME/Videos WEB_DIR=../../dist/web CEC=off \
  dart run bin/pi_tv_server.dart -v
# -> http://localhost:8787  (build the web remote first: tool/build-web.sh)
```

## Builds

| Artifact | Command | Output |
|---|---|---|
| Web remote | `tool/build-web.sh` | `dist/web/` (serve with `WEB_DIR`) |
| Android APK | `tool/build-apk.sh` | `dist/pi-tv-remote.apk` |
| Pi server | `tool/build-server-arm64.sh` | `dist/pi-tv-server-linux-arm64` |
| Pi bundle | `tool/package-release.sh` | `dist/pi-tv-linux-arm64.tar.gz` |

The server binary is compiled with
`dart compile exe --target-os=linux --target-arch=arm64` **inside a Debian 13
(Trixie) linux/arm64 container** (podman/docker + qemu-user-static), so its
glibc matches the Pi. Docker is only used to build; the Pi runs the binary
natively under systemd.

## Install on the Pi

See [docs/INSTALL.md](docs/INSTALL.md). Short version: copy
`dist/pi-tv-linux-arm64.tar.gz` to the Pi, unpack, `sudo ./install.sh`, then
open `http://<pi-address>:8787` and enter the PIN.

## Configuration

`/etc/pi-tv/pi-tv.env` (see `deploy/pi-tv.env.example`) or environment:

| Key | Default | |
|---|---|---|
| `PORT` | `8787` | bound on `0.0.0.0` (`BIND`) — LAN/WireGuard only, never port-forward |
| `TV_PIN` | generated | 6 digits `000000`–`999999`; if unset a random PIN is generated, logged and saved to `~/.pi-tv/pin` |
| `MEDIA_DIRS` | – | colon-separated folders, scanned recursively |
| `CEC` | `on` | `on`/`off` |
| `CHROMIUM_PATH`, `MPV_PATH` | PATH | |
| `WEB_DIR` | – | Flutter web build to serve at `/` |
| `DATA_DIR` | `~/.pi-tv` | PIN file, sessions, queue/history, thumbnails, Chromium profile, mpv socket |
| `CDP_PORT` | `9333` | Chromium DevTools port (Chromium binds it to 127.0.0.1) |
| `INHIBIT` | `on` | screen-blank inhibit while playing |
| `DISPLAY_MODE` | `auto` | `auto` (Wayland first, then X11), `wayland`, `x11` |
| `MPV_EXTRA_ARGS` | – | extra mpv flags, e.g. an HDMI audio device |
| `PUBLIC_URL` | detected | URL shown in the setup QR code |

Never commit a real PIN; `*.env` is git-ignored.

More detail on behaviour, the API and the tests: [docs/DESIGN.md](docs/DESIGN.md).
