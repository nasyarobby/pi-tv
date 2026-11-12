import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'api.dart';
import 'auth.dart';
import 'cec.dart';
import 'config.dart';
import 'display.dart';
import 'inhibit.dart';
import 'library/library_service.dart';
import 'library/metadata.dart';
import 'log.dart';
import 'playback.dart';
import 'players/chromium_player.dart';
import 'players/mpv_player.dart';
import 'players/player.dart';
import 'process.dart';
import 'store.dart';
import 'youtube_meta.dart';

/// Wires the real implementations together and serves HTTP.
class PiTvServer {
  PiTvServer(this.config);
  final ServerConfig config;
  final _log = Log('server');
  HttpServer? _http;
  late final PlaybackController playback;
  late final LibraryService library;
  late final AutoInhibitor _inhibitor;

  Future<HttpServer> start() async {
    Directory(config.dataDir).createSync(recursive: true);
    final runner = IoProcessRunner(onOutput: (exe, line) => Log(p.basename(exe)).debug(line));
    final detector = DisplayDetector(mode: config.displayMode);
    DisplayEnvironment display() => detector.detect();
    _log.info('display at startup: ${display()} (re-detected on every launch)');

    final pin = resolvePin(config);
    final auth = AuthService(
      pin: pin,
      sessions: SessionStore(store: JsonStore(p.join(config.dataDir, 'sessions.json'))),
    );

    library = LibraryService(
      config.mediaDirs,
      metadata: MetadataCache(runner, p.join(config.dataDir, 'cache'),
          ffprobe: config.ffprobePath, ffmpeg: config.ffmpegPath),
    );

    final chromium = ChromiumPlayer(
      runner: runner,
      display: display,
      userDataDir: chromiumProfileDir(config.dataDir),
      cdpPort: config.cdpPort,
      chromiumPath: config.chromiumPath,
    );
    final mpv = MpvPlayer(
      runner: runner,
      display: display,
      socketPath: p.join(config.dataDir, 'mpv.sock'),
      mpvPath: config.mpvPath,
      extraArgs: config.mpvExtraArgs,
    );
    _inhibitor = AutoInhibitor(runner, display);
    if (config.inhibit) await _inhibitor.recover();

    playback = PlaybackController(
      players: {MediaKind.youtube: chromium, MediaKind.local: mpv},
      resolve: (item) {
        switch (item.kind) {
          case MediaKind.youtube:
            return PlayTarget.youtube(YouTubeLink(item.source, startSeconds: item.startSeconds));
          case MediaKind.local:
            final f = library.byId(item.source);
            return f == null ? null : PlayTarget.file(f.absolutePath, startSeconds: item.startSeconds);
        }
      },
      inhibitor: config.inhibit ? _inhibitor : NoopInhibitor(),
      tv: config.cecEnabled ? CecTvControl(runner, cecClient: config.cecClientPath) : NoopTvControl(),
      queueStore: JsonStore(p.join(config.dataDir, 'queue.json')),
      historyStore: JsonStore(p.join(config.dataDir, 'history.json')),
    );

    final api = PiTvApi(
      auth: auth,
      playback: playback,
      library: library,
      titles: OEmbedTitleLookup(),
      webDir: config.webDir,
      setupInfo: defaultSetupInfo(config.port, publicUrl: config.publicUrl),
    );

    // Library scan on start (Rescan from a remote triggers it again).
    unawaited(library.rescan());

    final server = await shelf_io.serve(api.handler, config.bindAddress, config.port);
    server.autoCompress = true;
    _http = server;
    _log.info('Pi TV $serverVersion listening on http://${config.bindAddress}:${config.port} '
        '(media: ${config.mediaDirs.isEmpty ? 'none' : config.mediaDirs.join(':')}, CEC ${config.cecEnabled ? 'on' : 'off'})');
    if (config.webDir == null) _log.warn('WEB_DIR not set: the web remote will not be served');
    return server;
  }

  /// Shutdown: release the screen inhibit but leave TV windows alone.
  Future<void> stop() async {
    await _http?.close(force: true);
    await playback.dispose();
    await library.dispose();
  }
}
