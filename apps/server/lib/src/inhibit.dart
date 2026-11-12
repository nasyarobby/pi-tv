import 'dart:async';
import 'dart:io';

import 'display.dart';
import 'log.dart';
import 'process.dart';

/// Keeps the TV from blanking while something is playing.
abstract class ScreenInhibitor {
  bool get active;
  Future<void> acquire();
  Future<void> release();
}

class NoopInhibitor implements ScreenInhibitor {
  @override
  bool active = false;
  @override
  Future<void> acquire() async => active = true;
  @override
  Future<void> release() async => active = false;
}

/// Chooses the inhibitor for the detected display at acquire time, so the
/// service can start before the desktop session is up.
class AutoInhibitor implements ScreenInhibitor {
  AutoInhibitor(this._runner, this._detect, {Duration heartbeat = const Duration(seconds: 30)})
      : _heartbeat = heartbeat;
  final ProcessRunner _runner;
  final DisplayEnvironment Function() _detect;
  final Duration _heartbeat;
  ScreenInhibitor? _current;

  @override
  bool get active => _current?.active ?? false;

  @override
  Future<void> acquire() async {
    if (active) return;
    final env = _detect();
    _current = env.isX11 ? X11Inhibitor(_runner, env, heartbeat: _heartbeat) : WaylandInhibitor(_runner, env);
    await _current!.acquire();
  }

  @override
  Future<void> release() async {
    final c = _current;
    if (c == null) return;
    await c.release();
  }

  /// Undo a pause left behind by a crash (SIGCONT any stopped swayidle).
  Future<void> recover() => WaylandInhibitor(_runner, _detect()).resumeIdleDaemons();
}

/// Wayland (labwc / Raspberry Pi OS) inhibitor. Primary path.
///
/// Wayland has no global "disable screensaver" call for a background
/// service, so three layers are used:
///  1. mpv (`--stop-screensaver=yes`) and Chromium (video wake lock) set the
///     Wayland idle-inhibit protocol on their own surfaces while playing.
///  2. A `systemd-inhibit --what=idle:sleep` lock is held for logind-aware
///     idle managers and to prevent suspend.
///  3. The idle daemon (Raspberry Pi OS starts `swayidle` from the labwc
///     autostart for screen blanking) is paused with SIGSTOP and resumed
///     with SIGCONT on release; `wlopm --on '*'` wakes a blanked output.
class WaylandInhibitor implements ScreenInhibitor {
  WaylandInhibitor(this._runner, this._env, {this.idleDaemons = const ['swayidle', 'xfce4-power-manager']});
  final ProcessRunner _runner;
  final DisplayEnvironment _env;
  final List<String> idleDaemons;
  final _log = Log('inhibit');
  RunningProcess? _lock;
  @override
  bool active = false;

  Map<String, String> get _childEnv => {...Platform.environment, ..._env.childEnvironment};

  @override
  Future<void> acquire() async {
    if (active) return;
    active = true;
    final si = await _runner.which('systemd-inhibit');
    if (si != null) {
      try {
        _lock = await _runner.start(si, [
          '--what=idle:sleep',
          '--who=pi-tv',
          '--why=Playing on the TV',
          '--mode=block',
          'sleep',
          'infinity',
        ]);
      } catch (e) {
        _log.warn('systemd-inhibit failed: $e');
      }
    }
    await _signalIdleDaemons('STOP');
    final wlopm = await _runner.which('wlopm');
    if (wlopm != null) {
      await _runner.run(wlopm, ['--on', '*'], environment: _childEnv, timeout: const Duration(seconds: 5));
    }
    _log.info('screen blanking inhibited (wayland)');
  }

  Future<void> _signalIdleDaemons(String sig) async {
    final pkill = await _runner.which('pkill');
    if (pkill == null) return;
    final uid = DisplayDetector.currentUid();
    for (final d in idleDaemons) {
      await _runner.run(pkill, ['-$sig', '-u', '$uid', '-x', d], timeout: const Duration(seconds: 5));
    }
  }

  Future<void> resumeIdleDaemons() => _signalIdleDaemons('CONT');

  @override
  Future<void> release() async {
    if (!active) return;
    active = false;
    _lock?.kill();
    _lock = null;
    await _signalIdleDaemons('CONT');
    _log.info('screen blanking inhibit released (wayland)');
  }
}

/// X11 fallback: `xset s off -dpms` while playing plus a periodic
/// `xset s reset`, restored with `xset s on +dpms` on release.
class X11Inhibitor implements ScreenInhibitor {
  X11Inhibitor(this._runner, this._env, {this.heartbeat = const Duration(seconds: 30)});
  final ProcessRunner _runner;
  final DisplayEnvironment _env;
  final Duration heartbeat;
  final _log = Log('inhibit');
  Timer? _timer;
  @override
  bool active = false;

  Future<void> _xset(List<String> args) async {
    final xset = await _runner.which('xset');
    if (xset == null) return;
    await _runner.run(xset, args,
        environment: {...Platform.environment, ..._env.childEnvironment}, timeout: const Duration(seconds: 5));
  }

  @override
  Future<void> acquire() async {
    if (active) return;
    active = true;
    await _xset(['s', 'off']);
    await _xset(['-dpms']);
    await _xset(['s', 'reset']);
    _timer = Timer.periodic(heartbeat, (_) => _xset(['s', 'reset']));
    _log.info('screen blanking inhibited (x11)');
  }

  @override
  Future<void> release() async {
    if (!active) return;
    active = false;
    _timer?.cancel();
    _timer = null;
    await _xset(['s', 'on']);
    await _xset(['+dpms']);
    _log.info('screen blanking inhibit released (x11)');
  }
}
