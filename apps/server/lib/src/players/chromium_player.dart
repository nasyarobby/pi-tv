import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../display.dart';
import '../log.dart';
import '../process.dart';
import 'cdp.dart';
import 'player.dart';

/// JavaScript injected into every YouTube page: records the end of the
/// main video and keeps YouTube's "Autoplay next" off so a related video
/// never starts by itself. Inside a YouTube playlist that still has videos
/// left it does neither, so YouTube autoplays the next playlist video
/// (spec §5.7); related autoplay is blocked again on the last one.
final String youtubeGuardScript = r'''
/*pitv:guard*/(() => {
  if (window.__piTv) return;
  window.__piTv = { ended: false };
  const isAd = () => !!document.querySelector('#movie_player.ad-showing');
  // True while a YouTube playlist (list=) has videos after the current one,
  // or its length is not known yet: let YouTube advance on its own.
  const inOpenPlaylist = () => {
    try {
      if (!new URL(location.href).searchParams.get('list')) return false;
      const p = document.getElementById('movie_player');
      const pl = p && p.getPlaylist ? p.getPlaylist() : null;
      if (!pl || !pl.length) return true;
      return p.getPlaylistIndex() < pl.length - 1;
    } catch (e) { return false; }
  };
  const cancelAutonav = () => {
    document.querySelectorAll('.ytp-autonav-endscreen-cancel-button, .ytp-upnext-cancel-button')
      .forEach((b) => { try { b.click(); } catch (e) {} });
    const t = document.querySelector('.ytp-autonav-toggle-button[aria-checked="true"]');
    if (t) { try { t.click(); } catch (e) {} }
  };
  const fullBleed = () => {
    const on = /(^|\.)youtube\.com$/.test(location.hostname) && /^\/(watch|live\/)/.test(location.pathname);
    let st = document.getElementById('pitv-fullbleed');
    if (!st && on && document.documentElement) {
      st = document.createElement('style');
      st.id = 'pitv-fullbleed';
      st.textContent = PITV_FULL_BLEED_CSS;
      (document.head || document.documentElement).appendChild(st);
      st.disabled = true;
    }
    if (st && st.disabled === on) {
      st.disabled = !on;
      window.dispatchEvent(new Event('resize'));
    }
  };
  const hook = () => {
    fullBleed();
    const v = document.querySelector('video');
    if (v && !v.__piTvHooked) {
      v.__piTvHooked = true;
      v.addEventListener('ended', () => { if (!isAd() && !inOpenPlaylist()) { window.__piTv.ended = true; cancelAutonav(); } });
      v.addEventListener('playing', () => { if (!isAd()) window.__piTv.ended = false; });
    }
    if (!inOpenPlaylist()) cancelAutonav();
  };
  setInterval(hook, 500);
  document.addEventListener('DOMContentLoaded', hook);
  hook();
})();
'''
    .replaceFirst('PITV_FULL_BLEED_CSS', jsonEncode(youtubeFullBleedCss));

/// Full-bleed layout for YouTube watch pages, injected by
/// [youtubeGuardScript]. Without it the player only covers part of the
/// window: the normal layout puts it in a ~1337x752 box beside the related
/// videos, and theater mode (remembered in the persistent profile) gives a
/// full-width but shorter box under the masthead, so the 16:9 video is
/// pillarboxed with black bars left and right. This pins `#movie_player` to
/// the whole viewport (= the whole output, since the window is fullscreen at
/// the output size) and hides the page chrome. YouTube's own fullscreen (the
/// manual `f` toggle) still works on top of it. Ancestors of the player lose
/// transforms/containment and get a high z-index so the fixed player is not
/// trapped in, or painted under, another stacking context; YouTube dialogs
/// stay above it.
const String youtubeFullBleedCss = r'''
html, body { overflow: hidden !important; background: #000 !important; }
#masthead-container, ytd-masthead, #secondary, #below, tp-yt-app-drawer, ytd-mini-guide-renderer { visibility: hidden !important; }
ytd-app:has(#movie_player), ytd-app :has(#movie_player) { transform: none !important; filter: none !important; contain: none !important; will-change: auto !important; z-index: 2147483000 !important; }
#movie_player { position: fixed !important; left: 0 !important; top: 0 !important; right: 0 !important; bottom: 0 !important; width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important; margin: 0 !important; border-radius: 0 !important; z-index: 2147483000 !important; background: #000 !important; }
ytd-popup-container, tp-yt-iron-overlay-backdrop, ytd-consent-bump-v2-lightbox { z-index: 2147483647 !important; }
''';

/// Reads player state as JSON.
const String youtubeStateScript = r'''
/*pitv:state*/(() => {
  const v = document.querySelector('video');
  const p = document.getElementById('movie_player');
  let vid = null, list = null;
  try {
    const u = new URL(location.href);
    vid = u.searchParams.get('v');
    list = u.searchParams.get('list');
    if (!vid) { const m = u.pathname.match(/^\/(?:shorts|embed|live)\/([A-Za-z0-9_-]{11})/); if (m) vid = m[1]; }
  } catch (e) {}
  const ad = !!document.querySelector('#movie_player.ad-showing');
  let ps = -1;
  try { if (p && p.getPlayerState) ps = p.getPlayerState(); } catch (e) {}
  const ended = !ad && (ps === 0 || (!!v && v.ended) || !!(window.__piTv && window.__piTv.ended));
  let plIdx = null, plLen = null;
  try { if (list && p && p.getPlaylist) { const pl = p.getPlaylist(); if (pl && pl.length) { plLen = pl.length; plIdx = p.getPlaylistIndex(); } } } catch (e) {}
  let vol = v ? v.volume * 100 : 100, muted = v ? v.muted : false;
  try { if (p && p.getVolume) { vol = p.getVolume(); muted = p.isMuted(); } } catch (e) {}
  return JSON.stringify({
    vid, list, plIdx, plLen, path: location.pathname, url: location.href, title: document.title, hasVideo: !!v, ad,
    t: v ? v.currentTime : 0,
    d: v && isFinite(v.duration) ? v.duration : null,
    paused: v ? v.paused : true, ended, vol, muted,
    fs: !!document.fullscreenElement,
    view: [window.innerWidth, window.innerHeight, screen.width, screen.height, window.devicePixelRatio],
    box: (() => { if (!v) return null; const b = v.getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; })(),
    ready: !!v && !!p,
    error: !!(document.querySelector('.ytp-error') && document.querySelector('.ytp-error').offsetParent !== null),
  });
})()
''';

/// The persistent Chromium profile: `<DATA_DIR>/chromium-profile`. It is
/// never wiped (not on Stop, Close, queue changes or restarts), so cookies
/// and a Google/YouTube sign-in survive.
String chromiumProfileDir(String dataDir) => p.join(dataDir, 'chromium-profile');

String _cmd(String marker, String body) => '/*pitv:$marker*/(() => { $body })()';

/// YouTube in the system Chromium, driven over CDP.
///
/// A normal Chromium window (no kiosk) with a dedicated, persistent
/// `--user-data-dir` (a Google sign-in survives Close and restarts). The
/// window is opened at the detected output size (`--window-position=0,0
/// --window-size=WxH`) and `--start-fullscreen`; [youtubeFullBleedCss] makes
/// the YouTube player fill that whole window. The player is never put into
/// YouTube fullscreen automatically: [toggleFullscreen] sends one `f` when
/// the user presses Fullscreen on a remote.
class ChromiumPlayer implements Player {
  ChromiumPlayer({
    required ProcessRunner runner,
    required DisplayEnvironment Function() display,
    required this.userDataDir,
    this.cdpPort = 9333,
    this.chromiumPath,
    CdpEndpoint? endpoint,
    this.pollInterval = const Duration(seconds: 1),
    this.launchTimeout = const Duration(seconds: 40),
    this.loadTimeout = const Duration(seconds: 25),
    this.settleDelay = const Duration(milliseconds: 1500),
    this.playlistAdvanceGrace = const Duration(seconds: 10),
    Future<OutputSize?> Function(DisplayEnvironment env)? outputSize,
  })  : _runner = runner,
        _outputSize = outputSize ?? ((env) => detectOutputSize(runner, env)),
        _display = display,
        _endpoint = endpoint ?? HttpCdpEndpoint(cdpPort);

  final ProcessRunner _runner;
  final DisplayEnvironment Function() _display;
  final String userDataDir;
  final int cdpPort;
  final String? chromiumPath;
  final CdpEndpoint _endpoint;
  final Duration pollInterval;
  final Duration launchTimeout;
  final Duration loadTimeout;
  final Duration settleDelay;

  /// How long a playlist video may sit ended without YouTube moving on to
  /// the next playlist video before the item counts as ended anyway.
  final Duration playlistAdvanceGrace;
  final Future<OutputSize?> Function(DisplayEnvironment env) _outputSize;
  final _log = Log('chromium');

  RunningProcess? _process;
  CdpSession? _page;
  Timer? _poll;
  bool _polling = false;
  String? _expectedId;

  /// `list=` of the YouTube playlist being played (one queue item).
  String? _expectedList;
  bool _playlistFinished = false;
  DateTime? _endedSince;
  bool _forcedEnded = false;
  bool _navigating = false;
  OutputSize? _output;
  String? _targetId;
  PlayerSnapshot _snap = const PlayerSnapshot();
  final _snaps = StreamController<PlayerSnapshot>.broadcast();

  /// Arguments used for the last launch (exposed for tests and logs).
  List<String> lastLaunchArgs = const [];
  int launches = 0;

  @override
  MediaKind get kind => MediaKind.youtube;
  @override
  bool get isOpen => _snap.open;
  @override
  PlayerSnapshot get snapshot => _snap;
  @override
  Stream<PlayerSnapshot> get snapshots => _snaps.stream;

  void _emit(PlayerSnapshot s) {
    _snap = s;
    if (!_snaps.isClosed) _snaps.add(s);
  }

  Future<String> _resolveExecutable() async {
    if (chromiumPath != null) return chromiumPath!;
    for (final c in const ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable']) {
      final w = await _runner.which(c);
      if (w != null) return w;
    }
    throw StateError('Chromium not found; set CHROMIUM_PATH');
  }

  /// Output size detected for the last launch (null when unknown).
  OutputSize? get outputSize => _output;

  /// Launch flags. Exposed for tests/docs. With a known [output] the window
  /// starts at 0,0 with exactly the output's size before going fullscreen,
  /// so it never comes up as a smaller default-sized window.
  List<String> launchArgs(DisplayEnvironment env, String url, {OutputSize? output}) => [
        '--start-fullscreen',
        if (output != null) '--window-position=0,0',
        if (output != null) '--window-size=${output.width},${output.height}',
        '--remote-debugging-port=$cdpPort',
        '--user-data-dir=$userDataDir',
        '--no-first-run',
        '--no-default-browser-check',
        '--autoplay-policy=no-user-gesture-required',
        '--disable-session-crashed-bubble',
        '--hide-crash-restore-bubble',
        '--noerrdialogs',
        '--password-store=basic',
        '--disable-features=Translate,MediaRouter',
        if (env.isWayland) '--ozone-platform=wayland',
        if (env.isX11) '--ozone-platform=x11',
        url,
      ];

  Future<bool> _cdpUp() async => (await _endpoint.version()) != null;

  Future<void> _ensureBrowser(String url) async {
    if (_page != null && !_page!.isClosed && await _cdpUp()) return;
    var launchedNow = false;
    if (!await _cdpUp()) {
      final env = _display();
      final exe = await _resolveExecutable();
      Directory(userDataDir).createSync(recursive: true);
      _output = await _outputSize(env).catchError((Object e) {
        _log.debug('output size: $e');
        return null;
      });
      lastLaunchArgs = launchArgs(env, url, output: _output);
      _log.info('launching $exe on $env, output ${_output ?? 'size unknown'}');
      final proc =
          await _runner.start(exe, lastLaunchArgs, environment: {...Platform.environment, ...env.childEnvironment});
      _process = proc;
      launches++;
      launchedNow = true;
      unawaited(proc.exitCode.then((code) {
        if (identical(_process, proc)) {
          _log.info('chromium exited ($code)');
          _process = null;
          _onWindowGone();
        }
      }));
      final deadline = DateTime.now().add(launchTimeout);
      while (!await _cdpUp()) {
        if (DateTime.now().isAfter(deadline)) throw StateError('Chromium did not open the DevTools port $cdpPort');
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } else {
      _log.info('reusing running Chromium on CDP port $cdpPort');
    }
    Map<String, Object?>? target;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (target == null) {
      final pages = (await _endpoint.targets())
          .where((t) => t['type'] == 'page' && !('${t['url']}').startsWith('devtools://'))
          .toList();
      target = pages.firstWhere((t) => '${t['url']}'.contains('youtube.com'),
          orElse: () => pages.isEmpty ? <String, Object?>{} : pages.first);
      if (target.isEmpty) {
        target = null;
        if (!launchedNow || DateTime.now().isAfter(deadline)) {
          target = await _endpoint.newPage(url);
          if (target == null) throw StateError('could not open a Chromium tab');
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
    final ws = target['webSocketDebuggerUrl'] as String?;
    if (ws == null) throw StateError('Chromium target has no debugger URL');
    final page = await _endpoint.connect(ws);
    _page = page;
    unawaited(page.done.then((_) {
      if (identical(_page, page)) {
        _page = null;
        // The tab went away; check whether the browser is still up.
        _cdpUp().then((up) {
          if (!up) _onWindowGone();
        });
      }
    }));
    await page.send('Page.enable');
    await page.send('Runtime.enable');
    await page.send('Page.addScriptToEvaluateOnNewDocument', {'source': youtubeGuardScript});
    await _eval(youtubeGuardScript);
    _targetId = target['id'] as String?;
    await _ensureWindowFullscreen(_targetId);
    _emit(_snap.copyWith(open: true));
  }

  /// One-shot when the window is (re)attached: make the Chromium window
  /// fullscreen and, if it is smaller than the output, resize it to the
  /// output first. This is the browser window, not YouTube fullscreen.
  Future<void> _ensureWindowFullscreen(String? targetId) async {
    final page = _page;
    if (page == null || targetId == null) return;
    try {
      final w = await page.send('Browser.getWindowForTarget', {'targetId': targetId});
      final id = w['windowId'];
      if (id is! int) return;
      final bounds = (w['bounds'] as Map?)?.cast<String, Object?>() ?? const {};
      final out = _output;
      final width = (bounds['width'] as num?)?.toInt();
      final height = (bounds['height'] as num?)?.toInt();
      final small = out != null && width != null && height != null && (width < out.width || height < out.height);
      if (bounds['windowState'] == 'fullscreen' && !small) return;
      if (small) {
        _log.warn('Chromium window is ${width}x$height, output is $out; resizing it to the output');
        if (bounds['windowState'] != 'normal') {
          await page.send('Browser.setWindowBounds', {
            'windowId': id,
            'bounds': {'windowState': 'normal'},
          });
        }
        await page.send('Browser.setWindowBounds', {
          'windowId': id,
          'bounds': {'left': 0, 'top': 0, 'width': out.width, 'height': out.height},
        });
      }
      await page.send('Browser.setWindowBounds', {
        'windowId': id,
        'bounds': {'windowState': 'fullscreen'},
      });
    } on CdpException catch (e) {
      _log.debug('window fullscreen: $e');
    }
  }

  void _onWindowGone() {
    _poll?.cancel();
    _poll = null;
    _page = null;
    _emit(const PlayerSnapshot(open: false));
  }

  Future<Object?> _eval(String expression, {bool userGesture = false}) async {
    final page = _page;
    if (page == null) return null;
    final r = await page.send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
      'userGesture': userGesture,
    });
    final res = (r['result'] as Map?)?.cast<String, Object?>();
    return res?['value'];
  }

  Future<Map<String, Object?>?> _state() async {
    final v = await _eval(youtubeStateScript);
    if (v is! String) return null;
    final d = jsonDecode(v);
    return d is Map ? d.cast<String, Object?>() : null;
  }

  Future<void> _key(String key, String code, int vk) async {
    final page = _page;
    if (page == null) return;
    await page.send('Input.dispatchKeyEvent',
        {'type': 'keyDown', 'key': key, 'code': code, 'text': key, 'windowsVirtualKeyCode': vk});
    await page.send('Input.dispatchKeyEvent', {'type': 'keyUp', 'key': key, 'code': code, 'windowsVirtualKeyCode': vk});
  }

  Future<void> _clickPlayerCenter() async {
    final page = _page;
    if (page == null) return;
    final r = await _eval(_cmd('rect', '''
      const p = document.getElementById('movie_player') || document.querySelector('video');
      if (!p) return null; const b = p.getBoundingClientRect();
      return JSON.stringify({x: b.left + b.width / 2, y: b.top + b.height / 2});'''));
    if (r is! String) return;
    final pt = (jsonDecode(r) as Map).cast<String, Object?>();
    for (final type in const ['mousePressed', 'mouseReleased']) {
      await page.send(
          'Input.dispatchMouseEvent', {'type': type, 'x': pt['x'], 'y': pt['y'], 'button': 'left', 'clickCount': 1});
    }
  }

  @override
  Future<void> load(PlayTarget target) async {
    final link = target.link;
    if (link == null) throw ArgumentError('ChromiumPlayer only plays YouTube links');
    // list= and index are kept: a playlist is never opened as a bare video.
    final url = link.watchUrl.toString();
    _navigating = true;
    _forcedEnded = false;
    _expectedId = link.videoId;
    _expectedList = link.playlistId;
    _playlistFinished = false;
    _endedSince = null;
    try {
      await _ensureBrowser(url);
      final page = _page!;
      final st = await _state();
      final alreadyThere = link.videoId != null &&
          st?['vid'] == link.videoId &&
          st?['list'] == link.playlistId &&
          link.startSeconds == null &&
          link.playlistIndex == null;
      if (!alreadyThere) {
        _log.info('opening $url');
        await page.send('Page.navigate', {'url': url});
      }
      await page.send('Page.bringToFront');
      if (link.videoId == null) await _startPlaylistPage(link.playlistId!);
      final ready = await _waitForVideo();
      if (_expectedId == null && ready?['vid'] is String) _expectedId = ready!['vid'] as String;
      await _eval(youtubeGuardScript);
      await _startPlayback();
      await _logGeometry();
    } finally {
      _navigating = false;
    }
    _startPolling();
    await _tick();
  }

  /// Waits until the expected video (or, for a bare playlist link, any
  /// video of the expected playlist) has a player. Returns the last state.
  Future<Map<String, Object?>?> _waitForVideo() async {
    final deadline = DateTime.now().add(loadTimeout);
    while (true) {
      final s = await _state();
      final id = _expectedId;
      final ok = s != null &&
          s['hasVideo'] == true &&
          (id != null ? s['vid'] == id : s['vid'] != null && s['list'] == _expectedList);
      if (ok) return s;
      if (DateTime.now().isAfter(deadline)) {
        _log.warn('timed out waiting for the YouTube player of ${id ?? 'playlist $_expectedList'}');
        return s;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// A bare `playlist?list=` link opens YouTube's playlist page, which has
  /// no player. Start it like "Play all": open the first `watch?v=…&list=`
  /// link of that playlist on the page (the list stays in the URL).
  Future<void> _startPlaylistPage(String list) async {
    final page = _page;
    if (page == null) return;
    final deadline = DateTime.now().add(loadTimeout);
    final listJs = jsonEncode(list);
    while (true) {
      final s = await _state();
      if (s != null && s['vid'] != null && s['list'] == list) return; // already on a video of the playlist
      final href = await _eval(_cmd('playall', '''
        const want = $listJs;
        for (const a of document.querySelectorAll('a[href*="/watch?"]')) {
          try { const u = new URL(a.href, location.href); if (u.searchParams.get('list') === want && u.searchParams.get('v')) return u.href; } catch (e) {}
        }
        return null;'''));
      if (href is String && href.isNotEmpty) {
        _log.info('playlist page: starting $href');
        await page.send('Page.navigate', {'url': href});
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        final fallback = Uri.https('www.youtube.com', '/watch', {'list': list}).toString();
        _log.warn('playlist page has no video link; trying $fallback');
        await page.send('Page.navigate', {'url': fallback});
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<void> _startPlayback() async {
    await _eval(_cmd('play', '''
      const p = document.getElementById('movie_player'); const v = document.querySelector('video');
      try { if (p && p.playVideo) p.playVideo(); else if (v) v.play(); } catch (e) {}
      return true;'''), userGesture: true);
    await Future<void>.delayed(settleDelay);
    final s = await _state();
    if (s != null && s['paused'] == true && s['ended'] != true) {
      _log.info('autoplay blocked, clicking Play');
      await _eval(_cmd('playbutton', '''
        const b = document.querySelector('.ytp-large-play-button, .ytp-play-button');
        if (b) b.click(); return !!b;'''), userGesture: true);
      await Future<void>.delayed(settleDelay);
      final s2 = await _state();
      if (s2 != null && s2['paused'] == true) await _clickPlayerCenter();
    }
  }

  /// Logs the viewport and video size against the screen, so a player that
  /// does not fill the TV shows up in the log. Diagnostics only.
  Future<void> _logGeometry() async {
    try {
      final s = await _state();
      final view = s?['view'];
      final box = s?['box'];
      if (view is! List || view.length < 4) return;
      String n(Object? v) => (v as num?)?.round().toString() ?? '?';
      final msg = 'viewport ${n(view[0])}x${n(view[1])}, screen ${n(view[2])}x${n(view[3])}'
          '${view.length > 4 ? ' @${view[4]}x' : ''}'
          '${box is List && box.length == 4 ? ', video ${n(box[2])}x${n(box[3])} at ${n(box[0])},${n(box[1])}' : ''}'
          '${_output != null ? ', output $_output' : ''}';
      final full = box is List &&
          box.length == 4 &&
          (box[2] as num) >= (view[0] as num) - 2 &&
          (box[3] as num) >= (view[1] as num) - 2 &&
          (view[0] as num) >= (view[2] as num) - 2 &&
          (view[1] as num) >= (view[3] as num) - 2;
      if (full) {
        _log.info(msg);
      } else {
        _log.warn('YouTube video does not fill the screen: $msg');
      }
    } catch (e) {
      _log.debug('geometry: $e');
    }
  }

  /// Manual fullscreen from a remote: one `f` keystroke to the YouTube
  /// player (YouTube's own toggle). Never sent automatically.
  @override
  Future<void> toggleFullscreen() async {
    final page = _page;
    if (page == null || page.isClosed) return;
    try {
      await page.send('Page.bringToFront');
    } on CdpException catch (_) {}
    // YouTube ignores shortcuts while an input (e.g. the search box) has
    // focus, so blur it and focus the player first.
    await _eval(_cmd('focus', '''
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
      const p = document.getElementById('movie_player'); if (p) { p.focus(); } return !!p;'''));
    _log.info('fullscreen toggle (f) from remote');
    await _key('f', 'KeyF', 70);
    await _tick();
  }

  void _startPolling() {
    _poll ??= Timer.periodic(pollInterval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_polling || _page == null) return;
    _polling = true;
    try {
      final s = await _state();
      if (s == null) return;
      final vid = s['vid'] as String?;
      final list = s['list'] as String?;
      final expected = _expectedId;
      if (!_navigating && expected != null && vid != null && vid != expected) {
        if (_expectedList != null && list == _expectedList && !_playlistFinished) {
          // YouTube moved on inside our playlist: that is the playlist
          // playing through, not related-video autoplay.
          _log.info('playlist $list advanced to $vid');
          _expectedId = vid;
          _endedSince = null;
        } else {
          // YouTube navigated to a related video on its own: go back and
          // stay on the ended video.
          _log.warn('YouTube moved to $vid by itself; returning to $expected (ended)');
          await _returnToEnded(expected);
          return;
        }
      }
      if (s['error'] == true && !_snap.ended) _log.warn('YouTube player shows an error for $vid; treating it as ended');
      final plIdx = (s['plIdx'] as num?)?.toInt();
      final plLen = (s['plLen'] as num?)?.toInt();
      final rawEnded = s['ended'] == true || s['error'] == true;
      var ended = rawEnded;
      if (_expectedList != null) {
        if (!rawEnded) {
          _endedSince = null;
        } else if (plIdx == null || plLen == null || plIdx < plLen - 1) {
          // A playlist video ended with more to come: YouTube autoplays the
          // next one. Only if it does not within the grace period does the
          // item count as ended.
          final since = _endedSince ??= DateTime.now();
          ended = DateTime.now().difference(since) >= playlistAdvanceGrace;
          if (ended && !_playlistFinished) _log.warn('playlist $list did not advance; treating it as finished');
        }
        if (ended && !_playlistFinished) {
          _playlistFinished = true;
          if (plIdx != null && plLen != null && plIdx >= plLen - 1) _log.info('playlist $list finished');
        }
      }
      ended = _forcedEnded || ended;
      var title = s['title'] as String?;
      if (title != null) {
        title = title.replaceFirst(RegExp(r'^\(\d+\)\s*'), '').replaceFirst(RegExp(r'\s*-\s*YouTube$'), '');
        if (title.isEmpty || title == 'YouTube') title = null;
      }
      _emit(PlayerSnapshot(
        open: true,
        position: (s['t'] as num?)?.toDouble() ?? 0,
        duration: (s['d'] as num?)?.toDouble() ?? _snap.duration,
        paused: s['paused'] == true || ended,
        ended: ended,
        volume: (s['vol'] as num?)?.toDouble() ?? 100,
        muted: s['muted'] == true,
        title: title,
        playlistIndex: _expectedList != null && list == _expectedList ? plIdx : null,
        playlistLength: _expectedList != null && list == _expectedList ? plLen : null,
      ));
    } catch (e) {
      _log.debug('poll failed: $e');
    } finally {
      _polling = false;
    }
  }

  Future<void> _returnToEnded(String id) async {
    final page = _page;
    if (page == null) return;
    _navigating = true;
    _forcedEnded = true;
    if (_expectedList != null) _playlistFinished = true;
    try {
      await page.send('Page.navigate', {'url': YouTubeLink(id, playlistId: _expectedList).watchUrl.toString()});
      await _waitForVideo();
      await _eval(_cmd('toend', '''
        const p = document.getElementById('movie_player'); const v = document.querySelector('video');
        try { if (p && p.pauseVideo) p.pauseVideo(); if (v) { v.pause(); if (isFinite(v.duration)) v.currentTime = Math.max(0, v.duration - 0.5); } } catch (e) {}
        if (window.__piTv) window.__piTv.ended = true; return true;'''));
      _emit(_snap.copyWith(ended: true, paused: true, position: _snap.duration ?? _snap.position));
    } finally {
      _navigating = false;
    }
  }

  @override
  Future<void> play() async {
    _forcedEnded = false;
    await _eval(_cmd('resume', '''
      const p = document.getElementById('movie_player'); const v = document.querySelector('video');
      if (window.__piTv) window.__piTv.ended = false;
      try { if (p && p.playVideo) p.playVideo(); else if (v) v.play(); } catch (e) {} return true;'''),
        userGesture: true);
    await _tick();
  }

  @override
  Future<void> pause() async {
    await _eval(_cmd('pause', '''
      const p = document.getElementById('movie_player'); const v = document.querySelector('video');
      try { if (p && p.pauseVideo) p.pauseVideo(); else if (v) v.pause(); } catch (e) {} return true;'''));
    await _tick();
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> seek(double seconds) async {
    final s = seconds < 0 ? 0 : seconds;
    await _eval(_cmd('seek', '''
      const p = document.getElementById('movie_player'); const v = document.querySelector('video');
      try { if (p && p.seekTo) p.seekTo($s, true); else if (v) v.currentTime = $s; } catch (e) {} return true;'''));
    await _tick();
  }

  @override
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0, 100).round();
    await _eval(_cmd('volume', '''
      const p = document.getElementById('movie_player'); const v = document.querySelector('video');
      try { if (p && p.setVolume) { p.setVolume($v); if ($v > 0 && p.unMute) p.unMute(); } else if (v) { v.volume = $v / 100; } } catch (e) {} return true;'''));
    await _tick();
  }

  @override
  Future<void> setMuted(bool muted) async {
    await _eval(_cmd('mute', '''
      const p = document.getElementById('movie_player'); const v = document.querySelector('video');
      try { if (p && p.mute) { ${muted ? 'p.mute()' : 'p.unMute()'}; } else if (v) { v.muted = $muted; } } catch (e) {} return true;'''));
    await _tick();
  }

  @override
  Future<bool?> toggleSubtitles() async {
    await _key('c', 'KeyC', 67);
    return null;
  }

  /// Next/previous video inside the YouTube playlist being played. `false`
  /// for a single video, a finished playlist, or the last/first video, so
  /// the controller moves in our queue instead.
  @override
  Future<bool> skipInItem({required bool forward}) async {
    final page = _page;
    if (_expectedList == null || _playlistFinished || page == null || page.isClosed) return false;
    final s = await _state();
    if (s == null || s['list'] != _expectedList) return false;
    final idx = (s['plIdx'] as num?)?.toInt();
    final len = (s['plLen'] as num?)?.toInt();
    if (idx == null || len == null) return false;
    if (forward ? idx >= len - 1 : idx <= 0) return false;
    _log.info('${forward ? 'next' : 'previous'} inside playlist $_expectedList (${idx + 1}/$len)');
    _forcedEnded = false;
    _endedSince = null;
    await _eval(_cmd(forward ? 'plnext' : 'plprev', '''
      const p = document.getElementById('movie_player');
      if (window.__piTv) window.__piTv.ended = false;
      try { if (p) p.${forward ? 'nextVideo' : 'previousVideo'}(); } catch (e) {} return true;'''), userGesture: true);
    await _tick();
    return true;
  }

  /// Closes our Chromium even when this instance is not attached to it,
  /// e.g. a window left on the CDP port by a previous server run. The CDP
  /// port is dedicated to this app, so anything answering there is ours.
  @override
  Future<void> closeIfRunning() async {
    if (isOpen || _process != null || _page != null || await _cdpUp()) {
      if (!isOpen) _log.info('closing a Chromium this server was not attached to');
      await close();
    }
  }

  @override
  Future<void> close() async {
    _poll?.cancel();
    _poll = null;
    _expectedId = null;
    _expectedList = null;
    _playlistFinished = false;
    _endedSince = null;
    final page = _page;
    if (page != null && !page.isClosed) {
      try {
        await _eval(_cmd('exitfs', 'if (document.fullscreenElement) document.exitFullscreen(); return true;'));
      } catch (_) {}
    }
    final v = await _endpoint.version();
    final browserWs = v?['webSocketDebuggerUrl'] as String?;
    if (browserWs != null) {
      try {
        final b = await _endpoint.connect(browserWs);
        await b.send('Browser.close').catchError((Object _) => <String, Object?>{});
        await b.close();
      } catch (e) {
        _log.debug('Browser.close: $e');
      }
    }
    await page?.close().catchError((Object _) {});
    _page = null;
    final proc = _process;
    if (proc != null) {
      final code = await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
        proc.kill();
        return proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -9;
        });
      });
      _log.info('chromium closed ($code)');
    }
    _process = null;
    _emit(const PlayerSnapshot(open: false));
  }

  @override
  Future<void> dispose() async {
    _poll?.cancel();
    await _page?.close().catchError((Object _) {});
    await _snaps.close();
  }
}
