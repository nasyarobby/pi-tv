# Installing Pi TV on the Raspberry Pi

Target: Raspberry Pi 4, Debian 13 (Trixie) / Raspberry Pi OS, aarch64, desktop
session with auto-login (Wayland/labwc is the primary path; X11 also works).
The Pi must be on the home network. **Do not port-forward the server port.**

## 1. Build the artifacts (on any x86_64 Linux builder)

```sh
tool/build-server-arm64.sh   # dist/pi-tv-server-linux-arm64 (Trixie arm64 container)
tool/build-web.sh            # dist/web
tool/build-apk.sh            # dist/pi-tv-remote.apk
tool/package-release.sh      # dist/pi-tv-linux-arm64.tar.gz
```

## 2. Install on the Pi

```sh
scp dist/pi-tv-linux-arm64.tar.gz pi@<pi>:
ssh pi@<pi>
tar xzf pi-tv-linux-arm64.tar.gz && cd pi-tv
sudo ./install.sh pi          # your desktop user
```

`install.sh` installs `chromium mpv ffmpeg cec-utils` (plus `wlopm`,
`x11-xserver-utils` when available), copies the binary to
`/opt/pi-tv/pi-tv-server` and the web remote to `/opt/pi-tv/web`, creates
`/etc/pi-tv/pi-tv.env` (mode 600) from the example, installs
`/etc/systemd/system/pi-tv.service` for that user and starts it.

Then edit `/etc/pi-tv/pi-tv.env`:

* `MEDIA_DIRS=/home/pi/Videos:/media/pi/USB` — folders to list.
* `TV_PIN=` — six digits (leading zeros allowed). If you leave it unset, a
  random PIN is generated on first start: `sudo cat ~pi/.pi-tv/pin` or
  `journalctl -u pi-tv | grep PIN`.

`sudo systemctl restart pi-tv` after changes. Logs: `journalctl -u pi-tv -f`.

Manual install without the script: copy the three files above into place,
`systemctl daemon-reload && systemctl enable --now pi-tv`. A user-unit
variant is in `pi-tv.user.service`.

## 3. Use it

* Browser: `http://<pi-address>:8787` → PIN → paste a YouTube link, browse the
  library, control playback. **Rescan** in the Library tab re-scans
  `MEDIA_DIRS` (no shell needed).
* Android: install `pi-tv-remote.apk`, open it, scan the QR code from the web
  remote's menu → *Set up Android app* (`/setup`), or type the address, then
  enter the PIN. Share a video from the YouTube app → **Play on TV** →
  *Play now* / *Add to queue*.
  To open YouTube links directly with Pi TV, enable *Settings → Apps → Pi TV →
  Open by default → Add links* (Android 12+ does not let unverified apps claim
  YouTube links automatically).

## Desktop notes

* **Wayland (labwc, default on Raspberry Pi OS):** the server finds the
  compositor socket in `/run/user/<uid>/` and starts Chromium with
  `--ozone-platform=wayland`. Screen blanking (Raspberry Pi OS uses `swayidle`
  + `wlopm`) is held off while playing by: mpv/Chromium's own idle-inhibit,
  a `systemd-inhibit --what=idle:sleep` lock, and pausing `swayidle`
  (SIGSTOP, resumed with SIGCONT on stop/end, also on the next server start
  after a crash). `wlopm --on '*'` wakes a blanked output when playback starts.
* **X11:** `DISPLAY` / `/tmp/.X11-unix/X0` is used; blanking is held off with
  `xset s off -dpms` and restored with `xset s on +dpms`.
* **CEC:** `cec-client` (libcec, package `cec-utils`) sends `on 0` and `as`
  when playback starts; `cec-ctl` is used if `cec-client` is missing. Stop and
  Close never send standby. `CEC=off` disables it. The user needs access to
  `/dev/cec0` (group `video`).
* **Audio:** mpv and Chromium use the session's PipeWire. For a specific HDMI
  output, set `MPV_EXTRA_ARGS=--audio-device=...` (`mpv --audio-device=help`).
* Chromium uses its own profile in `~/.pi-tv/chromium-profile`, separate
  from your normal browser. Sign-in is not needed (v1 does not log in to
  YouTube).

## Manual on-device checklist

1. Play a YouTube link → Chromium opens fullscreen and the video fills the whole screen (no bars left/right). The Fullscreen button on the remote toggles YouTube's own fullscreen (`f`).
2. Let it end with an empty queue → window stays on the ended video, no related video starts.
3. Stop → paused, window open; screen may blank again after the idle timeout.
4. Play a local file → Chromium closes, mpv opens fullscreen with sidecar subtitles.
5. Close → mpv/Chromium closes, desktop visible, TV stays on.
6. TV in standby → play something → TV turns on and switches input (CEC).
7. Leave something playing past the blanking timeout → screen stays on.
8. Android: share from YouTube → Play now / Add to queue.
