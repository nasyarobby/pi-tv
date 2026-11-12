# Pi TV — design notes (implements spec v0.8)

## Playback rules

* One item plays at a time. `PlaybackController` owns the queue, the current
  item, history and which player is active.
* **YouTube → Chromium (CDP).** If nothing answers on `CDP_PORT`, the server
  starts `chromium --start-fullscreen --remote-debugging-port=<port>
  --user-data-dir=~/.pi-tv/chromium-profile --ozone-platform=wayland|x11
  <watch URL>` (plus `--no-first-run`, `--autoplay-policy=no-user-gesture-required`,
  no `--kiosk`). If it answers (window already open, even from a previous
  server run) the same tab is reused. Then: `Page.navigate` to
  `https://www.youtube.com/watch?v=<id>&t=<s>s`, bring to front, play
  (`movie_player.playVideo()`; if still paused, click the Play button, then a
  trusted mouse click), focus the player and send a trusted `f` key for
  player fullscreen (fallback: `requestFullscreen()` with a user gesture). The
  browser window itself is forced to `fullscreen` with `Browser.setWindowBounds`.
* **No related autoplay.** A guard script injected on every page turns
  YouTube's autoplay toggle off, cancels the up-next countdown and records the
  real end of the video. If YouTube still navigates to another video by
  itself, the server navigates back to ours, parks it at the end, paused, and
  reports `ended`.
* **Local → mpv** with `--fullscreen --hwdec=auto --keep-open=yes
  --input-ipc-server=~/.pi-tv/mpv.sock --idle=yes --force-window=yes
  --sub-auto=fuzzy --stop-screensaver=yes`; files are loaded with `loadfile`
  over the JSON IPC so the same mpv window is reused for the next local item
  (also across a server restart, via the existing socket). Sidecar `.srt/.vtt/.ass`
  next to the file are auto-loaded; `subtitles` toggles `sub-visibility`.
* **End of item:** next queued item starts (switching players if needed).
  With an empty queue the state becomes `ended`, the window stays open on the
  last frame / ended video, and the blanking inhibit is released.
* **Stop:** pause, window stays open, state `stopped`, inhibit released.
* **Close (remote only):** exit fullscreen + `Browser.close` (falls back to
  SIGTERM/SIGKILL of the process we started) and/or mpv `quit`. Nothing
  else closes windows, except switching kinds: YouTube → local closes
  Chromium first; local → YouTube quits mpv first.
* **CEC** (`on 0`, `as`) on every play start (debounced 20 s), never standby.
* **Inhibit** is held exactly while the state is `loading`/`playing`.
* If the window is closed on the Pi itself (or crashes) the state returns
  to `idle`; nothing is relaunched until a remote asks.

## Auth

* PIN: exactly 6 ASCII digits, leading zeros allowed. Invalid `TV_PIN` →
  server refuses to start (exit 78). No PIN → random one via `Random.secure`,
  logged once and written to `~/.pi-tv/pin` (0600); reused on later starts.
* `POST /api/login {pin}` → `{token, expiresAt}` + `Set-Cookie: pitv_session=…;
  HttpOnly; SameSite=Strict; Path=/`. Tokens are 256-bit random, stored as
  SHA-256 hashes in `~/.pi-tv/sessions.json` (180 days).
* Every `/api/*` and `/ws` route except `/api/login` and `/api/health` needs
  the cookie or `Authorization: Bearer <token>`. Static web files (which
  include the login page) are public. The PIN is never accepted in a query
  string and never in the QR code (`/api/setup-info` returns URLs only).
* 5 wrong (or malformed) PINs from one address lock that address for 5 minutes
  (HTTP 429 + `Retry-After`), even for the right PIN.
* The web remote keeps no token (cookie only). Android keeps the token (not the
  PIN) in `flutter_secure_storage` and goes back to the PIN screen on 401.

## API

| Method | Path | Body / query | Result |
|---|---|---|---|
| POST | `/api/login` | `{pin}` | `{token, expiresAt}` + cookie |
| POST | `/api/logout` | | revokes the session |
| GET | `/api/health` | | `{ok, version}` (public) |
| GET | `/api/status` | | now playing |
| WS | `/ws` | | pushes `{type: status|queue|history|library|error}`; accepts `{type:"control", action, value}` |
| POST | `/api/play` | `{url? , localPath?, startSeconds?, mode: now|queue}` | `{item, status}`; 400 for non-YouTube URL / file outside the library |
| POST | `/api/control` | `{action, value?}` — `play pause toggle stop close seek seekRelative volume mute next prev subtitles` | `{ok, status}` |
| GET | `/api/queue` | | `{items}` |
| PUT | `/api/queue` | `{order:[ids]}` or `{id, index}` | `{items}` |
| DELETE | `/api/queue` / `/api/queue/<id>` | | clear / remove |
| GET | `/api/library` | `?path=<folder>&q=<search>` | `{path, folders, items, total, scannedAt, scanning}` |
| POST | `/api/library/rescan` | | `{total, skipped, scannedAt}` (also pushed as a `library` WS event) |
| GET | `/api/thumb/<id>` | | JPEG thumbnail (ffmpeg, cached) |
| GET | `/api/history` | | `{items:[{item, playedAt}]}` (100 most recent) |
| GET | `/api/setup-info` | | `{url, candidates}` |

Now playing JSON: `kind, title, thumbnail, item, state (idle|loading|playing|
paused|stopped|ended), position, duration, volume, muted, queueLength,
windowOpen, subtitles, canPrevious`.

`localPath` is a library id (preferred) or an absolute path; only files the
scanner found inside `MEDIA_DIRS` are playable.

## Library

Scans every `MEDIA_DIRS` tree on start and on `POST /api/library/rescan`
(the Rescan button in both remotes). Extensions: mp4 mkv webm avi mov m4v
wmv mpeg mpg (case-insensitive). Skips dot-files/folders, `@eaDir`,
`#recycle`, `#snapshot`, `.Trash*`, `$RECYCLE.BIN`, `System Volume
Information`, `lost+found`, `__MACOSX`, `._*`; files that cannot be opened and
folders that cannot be listed are counted as skipped, the rest are listed;
symlink loops are ignored. Each root shows as a top-level folder (its
basename). Duration (`ffprobe`) and a thumbnail at ~10 % (`ffmpeg`) are
generated in the background and cached in `~/.pi-tv/cache`, keyed by size +
mtime. Folder watching is not implemented (optional in the spec).

## Remote UI

Login (6-digit numeric keypad, hardware digits work too) → tabs *Now playing*
(paste link / share text + Play now / Add to queue, artwork, scrubber, ±10 s,
play/pause, prev/next, volume, mute, subtitles for local, Stop, Close with a
confirmation), *Queue* (drag to reorder, swipe/remove, clear), *Library*
(folders, breadcrumbs, filename search, Rescan), *History* (one-tap replay).
Menu → *Set up Android app* opens `/setup` (URL + QR). Android: first-run
address screen (QR scan via camera or typed), share target / YouTube link
handler with a Play now / Add to queue sheet; a share that arrives before
setup/login is kept and offered right after login.

## Tests

* `packages/pi_tv_shared/test`: URL parser (all hosts, shorts/embed/live/music,
  messy share text, `t`/`start`/`t=1m30s`/fragment, rejection of look-alike
  and non-YouTube hosts), PIN format (leading zeros, non-6-digit rejection),
  generator, lockout window, models, API client.
* `apps/server/test`: PIN login success/failure/malformed/lockout/expiry,
  every protected route returns 401 without a session (incl. `/ws` and
  rescan), cookie + bearer, static/health public; scanner (extensions,
  nesting, junk, unreadable file/folder, missing root, symlink loop),
  rescan over HTTP refreshes the listing; queue mix + auto-advance,
  end-when-empty keeps the window and loads nothing, Stop vs Close, switching
  closes the other player, inhibit/CEC rules; Chromium CDP flow against a
  fake CDP endpoint (flags, reuse, `f`, autoplay-blocked click, related-video
  return, Close); mpv IPC against a fake socket; display detection; inhibit
  and CEC command lines; config parsing.
* `apps/remote/test`: keypad, login, paste/validate, Stop/Close, Rescan,
  library queueing, Android first run, share before setup, share while
  running, `/setup` QR.
* Manual on-device checklist: docs/INSTALL.md.
