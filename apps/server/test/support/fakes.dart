import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

class RunCall {
  RunCall(this.exe, this.args, this.stdinText);
  final String exe;
  final List<String> args;
  final String? stdinText;
  @override
  String toString() => '$exe ${args.join(' ')}${stdinText == null ? '' : ' <<< ${stdinText!.trim()}'}';
}

class FakeProcess implements RunningProcess {
  FakeProcess(this.pid);
  @override
  final int pid;
  final _exit = Completer<int>();
  final List<ProcessSignal> signals = [];
  @override
  Future<int> get exitCode => _exit.future;
  bool get exited => _exit.isCompleted;
  void exit([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    exit(-15);
    return true;
  }

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);
}

class FakeRunner implements ProcessRunner {
  FakeRunner({Set<String>? available}) : available = available ?? {};
  final Set<String> available;
  final List<RunCall> runs = [];
  final List<RunCall> starts = [];
  final List<FakeProcess> processes = [];
  CommandResult Function(RunCall c)? onRun;
  void Function(RunCall c, FakeProcess p)? onStart;

  @override
  Future<CommandResult> run(String executable, List<String> args,
      {Map<String, String>? environment, String? stdinText, Duration timeout = const Duration(seconds: 30)}) async {
    final c = RunCall(executable, args, stdinText);
    runs.add(c);
    return onRun?.call(c) ?? const CommandResult(0, '', '');
  }

  @override
  Future<RunningProcess> start(String executable, List<String> args, {Map<String, String>? environment}) async {
    final c = RunCall(executable, args, null);
    starts.add(c);
    final p = FakeProcess(1000 + processes.length);
    processes.add(p);
    onStart?.call(c, p);
    return p;
  }

  @override
  Future<String?> which(String name) async => available.contains(name) ? '/usr/bin/$name' : null;
}

/// Scriptable in-memory player.
class FakePlayer implements Player {
  FakePlayer(this.kind);
  @override
  final MediaKind kind;
  final List<String> calls = [];
  final List<PlayTarget> loads = [];
  PlayerSnapshot _snap = const PlayerSnapshot();
  final _ctrl = StreamController<PlayerSnapshot>.broadcast(sync: true);
  int closes = 0;
  Object? failNextLoad;

  @override
  bool get isOpen => _snap.open;
  @override
  PlayerSnapshot get snapshot => _snap;
  @override
  Stream<PlayerSnapshot> get snapshots => _ctrl.stream;

  void emit(PlayerSnapshot s) {
    _snap = s;
    _ctrl.add(s);
  }

  /// Simulates the item reaching its end (window stays open).
  void finish() => emit(_snap.copyWith(ended: true, paused: true, position: _snap.duration ?? 10));

  /// Simulates the window being closed outside the server.
  void crash() => emit(const PlayerSnapshot(open: false));

  @override
  Future<void> load(PlayTarget target) async {
    calls.add('load');
    final f = failNextLoad;
    if (f != null) {
      failNextLoad = null;
      throw f;
    }
    loads.add(target);
    emit(const PlayerSnapshot(open: true, paused: false, duration: 10));
  }

  @override
  Future<void> play() async {
    calls.add('play');
    emit(_snap.copyWith(paused: false, ended: false));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emit(_snap.copyWith(paused: true));
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    emit(_snap.copyWith(paused: true));
  }

  @override
  Future<void> seek(double seconds) async {
    calls.add('seek:$seconds');
    emit(_snap.copyWith(position: seconds, ended: false));
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('volume:$volume');
    emit(_snap.copyWith(volume: volume));
  }

  @override
  Future<void> setMuted(bool muted) async {
    calls.add('mute:$muted');
    emit(_snap.copyWith(muted: muted));
  }

  @override
  Future<bool?> toggleSubtitles() async {
    calls.add('subtitles');
    final v = !(_snap.subtitles ?? true);
    emit(_snap.copyWith(subtitles: v));
    return v;
  }

  @override
  Future<void> toggleFullscreen() async => calls.add('fullscreen');

  @override
  Future<void> close() async {
    calls.add('close');
    closes++;
    emit(const PlayerSnapshot(open: false));
  }

  @override
  Future<void> dispose() async {}
}

class CountingInhibitor implements ScreenInhibitor {
  @override
  bool active = false;
  int acquires = 0;
  int releases = 0;
  @override
  Future<void> acquire() async {
    if (!active) acquires++;
    active = true;
  }

  @override
  Future<void> release() async {
    if (active) releases++;
    active = false;
  }
}

class CountingTv implements TvControl {
  int wakes = 0;
  @override
  Future<void> wakeAndSelect() async => wakes++;
}

/// Simulated Chromium page for CDP tests.
class FakeYouTubePage {
  String url = 'about:blank';
  bool hasVideo = false;
  double t = 0;
  double? d = 100;
  bool paused = true;
  bool ended = false;
  bool fullscreen = false;
  bool autoplayBlocked = false;

  int fKeys = 0;

  /// Viewport/screen reported by the page.
  List<num> view = [1920, 1080, 1920, 1080, 1];
  double volume = 100;
  bool muted = false;
  String title = 'YouTube';

  String? get vid {
    final u = Uri.tryParse(url);
    return u?.queryParameters['v'];
  }

  Map<String, Object?> state() {
    return {
      'vid': vid,
      'url': url,
      'title': title,
      'hasVideo': hasVideo,
      'ad': false,
      't': t,
      'd': d,
      'paused': paused,
      'ended': ended,
      'vol': volume,
      'muted': muted,
      'fs': fullscreen,
      'view': view,
      'box': hasVideo ? [0, 0, view[0], view[1]] : null,
      'ready': hasVideo,
      'error': false,
    };
  }
}

class FakeCdpSession implements CdpSession {
  FakeCdpSession(this.endpoint, this.isBrowser);
  final FakeCdpEndpoint endpoint;
  final bool isBrowser;
  final _done = Completer<void>();
  final _events = StreamController<CdpEvent>.broadcast();

  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<void> get done => _done.future;
  @override
  Stream<CdpEvent> get events => _events.stream;

  @override
  Future<Map<String, Object?>> send(String method, [Map<String, Object?> params = const {}]) async {
    endpoint.log.add(method == 'Runtime.evaluate' ? 'eval:${_marker(params['expression'] as String)}' : method);
    final page = endpoint.page;
    switch (method) {
      case 'Page.navigate':
        page.url = params['url'] as String;
        page.hasVideo = true;
        page.ended = false;
        page.t = 0;
        page.paused = true;
        page.fullscreen = false; // a navigation leaves document fullscreen
        if (!page.autoplayBlocked) page.paused = false;
        return {};
      case 'Input.dispatchKeyEvent':
        if (params['type'] == 'keyDown') endpoint.keys.add(params['key'] as String);
        if (params['type'] == 'keyDown' && params['key'] == 'f') {
          page.fKeys++;
          page.fullscreen = !page.fullscreen;
        }
        return {};
      case 'Input.dispatchMouseEvent':
        if (params['type'] == 'mouseReleased') page.paused = false;
        return {};
      case 'Browser.close':
        endpoint.browserClosed = true;
        endpoint.up = false;
        endpoint.onBrowserClose?.call();
        return {};
      case 'Browser.getWindowForTarget':
        return {'windowId': 1, 'bounds': Map<String, Object?>.of(endpoint.windowBounds)};
      case 'Browser.setWindowBounds':
        final b = (params['bounds']! as Map).cast<String, Object?>();
        endpoint.setBounds.add(b);
        endpoint.windowBounds.addAll(b);
        return {};
      case 'Runtime.evaluate':
        return {
          'result': {'value': _evaluate(params['expression'] as String, params['userGesture'] == true)}
        };
    }
    return {};
  }

  static String _marker(String expr) {
    final m = RegExp(r'/\*pitv:(\w+)\*/').firstMatch(expr);
    return m?.group(1) ?? '?';
  }

  Object? _evaluate(String expr, bool gesture) {
    final page = endpoint.page;
    switch (_marker(expr)) {
      case 'state':
        return jsonEncode(page.state());
      case 'play':
      case 'resume':
        if (!page.autoplayBlocked || gesture && _marker(expr) == 'resume') page.paused = false;
        page.ended = false;
        return true;
      case 'playbutton':
        page.paused = false;
        return true;
      case 'pause':
        page.paused = true;
        return true;
      case 'seek':
        page.t = double.parse(RegExp(r'seekTo\(([\d.]+)').firstMatch(expr)!.group(1)!);
        return true;
      case 'volume':
        page.volume = double.parse(RegExp(r'setVolume\((\d+)\)').firstMatch(expr)!.group(1)!);
        return true;
      case 'toend':
        page.paused = true;
        page.ended = true;
        page.t = page.d ?? 0;
        return true;
      case 'exitfs':
        page.fullscreen = false;
        return true;
      case 'rect':
        return jsonEncode({'x': 100, 'y': 100});
    }
    return true;
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeCdpEndpoint implements CdpEndpoint {
  bool up = false;
  bool browserClosed = false;
  final page = FakeYouTubePage();
  final List<String> log = [];
  final List<String> keys = [];
  void Function()? onBrowserClose;

  /// What `Browser.getWindowForTarget` reports; `Browser.setWindowBounds`
  /// calls are recorded in [setBounds] and merged into it.
  final Map<String, Object?> windowBounds = {
    'left': 0,
    'top': 0,
    'width': 1920,
    'height': 1080,
    'windowState': 'fullscreen'
  };
  final List<Map<String, Object?>> setBounds = [];

  @override
  Future<Map<String, Object?>?> version() async =>
      up ? {'Browser': 'Chromium/150', 'webSocketDebuggerUrl': 'ws://127.0.0.1/devtools/browser/x'} : null;

  @override
  Future<List<Map<String, Object?>>> targets() async => up
      ? [
          {'id': 'T1', 'type': 'page', 'url': page.url, 'webSocketDebuggerUrl': 'ws://127.0.0.1/devtools/page/T1'}
        ]
      : [];

  @override
  Future<Map<String, Object?>?> newPage(String url) async {
    page.url = url;
    return {'id': 'T1', 'type': 'page', 'url': url, 'webSocketDebuggerUrl': 'ws://127.0.0.1/devtools/page/T1'};
  }

  @override
  Future<CdpSession> connect(String webSocketDebuggerUrl) async =>
      FakeCdpSession(this, webSocketDebuggerUrl.contains('/browser/'));
}

/// mpv IPC fake: records commands and lets tests push property events.
class FakeMpvIpc implements MpvIpc {
  final List<List<Object?>> commands = [];
  final _events = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final _done = Completer<void>();
  final Map<String, Object?> props = {'sub-visibility': true};
  void Function()? onQuit;

  void property(String name, Object? data) => _events.add({'event': 'property-change', 'name': name, 'data': data});

  @override
  Future<Object?> command(List<Object?> args) async {
    commands.add(args);
    switch (args.first) {
      case 'cycle':
        props[args[1] as String] = !(props[args[1]] as bool? ?? false);
        property(args[1] as String, props[args[1]]);
      case 'get_property':
        return props[args[1]];
      case 'set_property':
        props[args[1] as String] = args[2];
        property(args[1] as String, args[2]);
      case 'quit':
        onQuit?.call();
        await close();
    }
    return null;
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> get done => _done.future;
  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeMpvConnector implements MpvIpcConnector {
  FakeMpvIpc? current;
  int connects = 0;
  bool available = false;
  void Function(FakeMpvIpc ipc)? onConnect;
  @override
  Future<MpvIpc> connect(String socketPath) async {
    connects++;
    if (!available) throw const SocketException('no socket');
    final ipc = current = FakeMpvIpc();
    onConnect?.call(ipc);
    return ipc;
  }
}

/// Lets queued microtasks/timers run.
Future<void> pump([int times = 5]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
