import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pi_tv_shared/pi_tv_shared.dart';

import '../display.dart';
import '../log.dart';
import '../process.dart';
import 'player.dart';

/// JSON IPC connection to mpv (`--input-ipc-server`).
abstract class MpvIpc {
  Future<Object?> command(List<Object?> args);
  Stream<Map<String, Object?>> get events;
  Future<void> get done;
  bool get isClosed;
  Future<void> close();
}

abstract class MpvIpcConnector {
  Future<MpvIpc> connect(String socketPath);
}

class MpvIpcException implements Exception {
  MpvIpcException(this.message);
  final String message;
  @override
  String toString() => 'MpvIpcException: $message';
}

class UnixSocketMpvConnector implements MpvIpcConnector {
  @override
  Future<MpvIpc> connect(String socketPath) async {
    final s = await Socket.connect(InternetAddress(socketPath, type: InternetAddressType.unix), 0)
        .timeout(const Duration(seconds: 3));
    return SocketMpvIpc(s);
  }
}

class SocketMpvIpc implements MpvIpc {
  SocketMpvIpc(this._socket) {
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: (Object _) => _onDone());
  }
  final Socket _socket;
  int _next = 1;
  final Map<int, Completer<Object?>> _pending = {};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _done = Completer<void>();

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? m;
    try {
      m = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (m is! Map) return;
    final map = m.cast<String, Object?>();
    final id = map['request_id'];
    if (id is int && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      if (map['error'] == 'success') {
        c.complete(map['data']);
      } else {
        c.completeError(MpvIpcException('${map['error']}'));
      }
    } else if (map['event'] is String) {
      _events.add(map);
    }
  }

  void _onDone() {
    for (final c in _pending.values) {
      c.completeError(MpvIpcException('mpv IPC closed'));
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
    _events.close();
  }

  @override
  Future<Object?> command(List<Object?> args) {
    if (isClosed) return Future.error(MpvIpcException('mpv IPC closed'));
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _socket.write('${jsonEncode({'command': args, 'request_id': id})}\n');
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _pending.remove(id);
      throw MpvIpcException('timeout: ${args.first}');
    });
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
    _onDone();
  }
}

/// Local files in mpv: fullscreen, hardware decoding, keep-open, IPC.
class MpvPlayer implements Player {
  MpvPlayer({
    required ProcessRunner runner,
    required DisplayEnvironment Function() display,
    required this.socketPath,
    this.mpvPath,
    this.extraArgs = const [],
    MpvIpcConnector? connector,
    this.connectTimeout = const Duration(seconds: 15),
  })  : _runner = runner,
        _display = display,
        _connector = connector ?? UnixSocketMpvConnector();

  final ProcessRunner _runner;
  final DisplayEnvironment Function() _display;
  final String socketPath;
  final String? mpvPath;

  /// Extra mpv flags from `MPV_EXTRA_ARGS` (e.g. `--audio-device=...`).
  final List<String> extraArgs;
  final MpvIpcConnector _connector;
  final Duration connectTimeout;
  final _log = Log('mpv');

  RunningProcess? _process;
  MpvIpc? _ipc;
  PlayerSnapshot _snap = const PlayerSnapshot();
  final _snaps = StreamController<PlayerSnapshot>.broadcast();
  bool _loading = false;
  List<String> lastLaunchArgs = const [];
  int launches = 0;

  @override
  MediaKind get kind => MediaKind.local;
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

  List<String> launchArgs(DisplayEnvironment env) => [
        '--fullscreen',
        '--hwdec=auto',
        '--keep-open=yes',
        '--input-ipc-server=$socketPath',
        '--idle=yes',
        '--force-window=yes',
        '--sub-auto=fuzzy',
        '--stop-screensaver=yes',
        '--no-terminal',
        '--title=Pi TV',
        ...extraArgs,
      ];

  Future<void> _ensureRunning() async {
    if (_ipc != null && !_ipc!.isClosed) return;
    final sock = File(socketPath);
    if (FileSystemEntity.typeSync(socketPath) == FileSystemEntityType.unixDomainSock) {
      // An mpv from a previous server run may still be open: reuse it.
      try {
        final existing = await _connector.connect(socketPath);
        _log.info('reusing running mpv on $socketPath');
        await _attach(existing);
        return;
      } catch (_) {
        // stale socket
      }
    }
    if (sock.existsSync()) sock.deleteSync();
    final env = _display();
    final exe = mpvPath ?? await _runner.which('mpv') ?? 'mpv';
    sock.parent.createSync(recursive: true);
    lastLaunchArgs = launchArgs(env);
    _log.info('launching $exe on $env');
    final proc =
        await _runner.start(exe, lastLaunchArgs, environment: {...Platform.environment, ...env.childEnvironment});
    _process = proc;
    launches++;
    unawaited(proc.exitCode.then((code) {
      if (identical(_process, proc)) {
        _log.info('mpv exited ($code)');
        _process = null;
        _ipc = null;
        _emit(const PlayerSnapshot(open: false));
      }
    }));
    final deadline = DateTime.now().add(connectTimeout);
    MpvIpc? ipc;
    while (ipc == null) {
      try {
        ipc = await _connector.connect(socketPath);
      } catch (_) {
        if (_process == null) throw StateError('mpv exited before its IPC socket came up');
        if (DateTime.now().isAfter(deadline)) {
          proc.kill();
          throw StateError('mpv IPC socket did not come up at $socketPath');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    await _attach(ipc);
  }

  Future<void> _attach(MpvIpc ipc) async {
    _ipc = ipc;
    ipc.events.listen(_onEvent);
    unawaited(ipc.done.then((_) {
      if (identical(_ipc, ipc) && _process == null) {
        _ipc = null;
        _emit(const PlayerSnapshot(open: false));
      }
    }));
    var i = 1;
    for (final prop in const [
      'time-pos',
      'duration',
      'pause',
      'eof-reached',
      'volume',
      'mute',
      'media-title',
      'sub-visibility'
    ]) {
      await ipc.command(['observe_property', i++, prop]);
    }
    _emit(_snap.copyWith(open: true));
  }

  void _onEvent(Map<String, Object?> e) {
    if (e['event'] != 'property-change') return;
    final data = e['data'];
    switch (e['name']) {
      case 'time-pos':
        if (data is num) _emit(_snap.copyWith(position: data.toDouble()));
      case 'duration':
        if (data is num) _emit(_snap.copyWith(duration: data.toDouble()));
      case 'pause':
        if (data is bool) _emit(_snap.copyWith(paused: data));
      case 'eof-reached':
        if (_loading) return;
        _emit(_snap.copyWith(ended: data == true, paused: data == true ? true : null));
      case 'volume':
        if (data is num) _emit(_snap.copyWith(volume: data.toDouble()));
      case 'mute':
        if (data is bool) _emit(_snap.copyWith(muted: data));
      case 'media-title':
        if (data is String) _emit(_snap.copyWith(title: data));
      case 'sub-visibility':
        if (data is bool) _emit(_snap.copyWith(subtitles: data));
    }
  }

  Future<Object?> _cmd(List<Object?> args) async {
    final ipc = _ipc;
    if (ipc == null) return null;
    return ipc.command(args);
  }

  @override
  Future<void> load(PlayTarget target) async {
    final path = target.filePath;
    if (path == null) throw ArgumentError('MpvPlayer only plays local files');
    _loading = true;
    try {
      await _ensureRunning();
      final start = target.startSeconds;
      await _cmd(['set_property', 'start', start != null && start > 0 ? '$start' : 'none']);
      await _cmd(['loadfile', path, 'replace']);
      await _cmd(['set_property', 'fullscreen', true]);
      await _cmd(['set_property', 'pause', false]);
      _emit(PlayerSnapshot(
          open: true, paused: false, volume: _snap.volume, muted: _snap.muted, subtitles: _snap.subtitles));
    } finally {
      _loading = false;
    }
  }

  @override
  Future<void> play() async {
    if (_snap.ended) {
      // keep-open parks on the last frame; play from the start again.
      await _cmd(['seek', 0, 'absolute']);
    }
    await _cmd(['set_property', 'pause', false]);
  }

  @override
  Future<void> pause() async => _cmd(['set_property', 'pause', true]);

  /// Stop leaves mpv open on the current/last frame.
  @override
  Future<void> stop() => pause();

  @override
  Future<void> seek(double seconds) async => _cmd(['seek', seconds < 0 ? 0 : seconds, 'absolute']);

  @override
  Future<void> setVolume(double volume) async => _cmd(['set_property', 'volume', volume.clamp(0, 100)]);

  @override
  Future<void> setMuted(bool muted) async => _cmd(['set_property', 'mute', muted]);

  @override
  Future<bool?> toggleSubtitles() async {
    await _cmd(['cycle', 'sub-visibility']);
    final v = await _cmd(['get_property', 'sub-visibility']);
    return v is bool ? v : null;
  }

  @override
  Future<void> close() async {
    final proc = _process;
    final ipc = _ipc;
    if (ipc != null && !ipc.isClosed) {
      // mpv exits without always answering `quit`; don't wait for a reply.
      unawaited(ipc.command(['quit']).then((_) {}, onError: (Object _) {}));
      if (proc == null) {
        await ipc.done.timeout(const Duration(seconds: 5), onTimeout: () {});
      }
    }
    if (proc != null) {
      await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
        proc.kill();
        return proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -9;
        });
      });
    }
    await _ipc?.close().catchError((Object _) {});
    _ipc = null;
    _process = null;
    final sock = File(socketPath);
    if (sock.existsSync()) {
      try {
        sock.deleteSync();
      } catch (_) {}
    }
    _emit(const PlayerSnapshot(open: false));
  }

  @override
  Future<void> dispose() async {
    await _ipc?.close().catchError((Object _) {});
    await _snaps.close();
  }
}
