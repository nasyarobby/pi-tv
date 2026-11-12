import 'dart:io';

import 'package:path/path.dart' as p;

import 'process.dart';

enum DisplayKind { wayland, x11, none }

/// The graphical session the TV players should attach to.
class DisplayEnvironment {
  const DisplayEnvironment(this.kind, {this.waylandDisplay, this.x11Display, this.runtimeDir, this.xauthority});

  final DisplayKind kind;
  final String? waylandDisplay;
  final String? x11Display;
  final String? runtimeDir;
  final String? xauthority;

  bool get isWayland => kind == DisplayKind.wayland;
  bool get isX11 => kind == DisplayKind.x11;

  /// Environment overrides for child processes (Chromium, mpv, xset...).
  Map<String, String> get childEnvironment => {
        if (runtimeDir != null) 'XDG_RUNTIME_DIR': runtimeDir!,
        if (isWayland && waylandDisplay != null) 'WAYLAND_DISPLAY': waylandDisplay!,
        if (isWayland) 'XDG_SESSION_TYPE': 'wayland',
        if (isX11) 'XDG_SESSION_TYPE': 'x11',
        if (x11Display != null) 'DISPLAY': x11Display!,
        if (xauthority != null) 'XAUTHORITY': xauthority!,
      };

  @override
  String toString() => switch (kind) {
        DisplayKind.wayland => 'wayland($waylandDisplay, runtime=$runtimeDir)',
        DisplayKind.x11 => 'x11($x11Display)',
        DisplayKind.none => 'none',
      };
}

/// Detects Wayland (primary) or X11 (fallback) at runtime.
///
/// Order: explicit [mode]; `WAYLAND_DISPLAY`; a `wayland-*` socket in the
/// user's runtime dir (the systemd service usually has no session env);
/// `DISPLAY`; an X socket in `/tmp/.X11-unix`.
class DisplayDetector {
  DisplayDetector({
    Map<String, String>? environment,
    this.mode = 'auto',
    int? uid,
    this.x11SocketDir = '/tmp/.X11-unix',
    String? home,
  })  : _env = environment ?? Platform.environment,
        _uid = uid,
        _home = home;

  final Map<String, String> _env;
  final String mode;
  final int? _uid;
  final String x11SocketDir;
  final String? _home;

  int get uid => _uid ?? currentUid();

  static int currentUid() {
    try {
      for (final line in File('/proc/self/status').readAsLinesSync()) {
        if (line.startsWith('Uid:')) {
          return int.parse(line.split(RegExp(r'\s+'))[1]);
        }
      }
    } catch (_) {}
    return 1000;
  }

  String get runtimeDir => _env['XDG_RUNTIME_DIR'] ?? '/run/user/$uid';

  String? _findWaylandSocket(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return null;
    final names = <String>[];
    try {
      for (final e in d.listSync()) {
        final n = p.basename(e.path);
        if (RegExp(r'^wayland-\d+$').hasMatch(n) &&
            FileSystemEntity.typeSync(e.path) == FileSystemEntityType.unixDomainSock) {
          names.add(n);
        }
      }
    } on FileSystemException {
      return null;
    }
    names.sort();
    return names.isEmpty ? null : names.first;
  }

  String? _findX11Display() {
    final d = Directory(x11SocketDir);
    if (!d.existsSync()) return null;
    final nums = <int>[];
    try {
      for (final e in d.listSync()) {
        final m = RegExp(r'^X(\d+)$').firstMatch(p.basename(e.path));
        if (m != null) nums.add(int.parse(m.group(1)!));
      }
    } on FileSystemException {
      return null;
    }
    nums.sort();
    return nums.isEmpty ? null : ':${nums.first}';
  }

  String? get _xauth {
    final x = _env['XAUTHORITY'];
    if (x != null) return x;
    final h = _home ?? _env['HOME'];
    if (h != null && File(p.join(h, '.Xauthority')).existsSync()) return p.join(h, '.Xauthority');
    return null;
  }

  DisplayEnvironment detect() {
    final rt = runtimeDir;
    DisplayEnvironment? wayland() {
      final wd = _env['WAYLAND_DISPLAY'];
      if (wd != null && wd.isNotEmpty) {
        return DisplayEnvironment(DisplayKind.wayland, waylandDisplay: wd, runtimeDir: rt, x11Display: _env['DISPLAY']);
      }
      final sock = _findWaylandSocket(rt);
      if (sock != null) {
        return DisplayEnvironment(DisplayKind.wayland,
            waylandDisplay: sock, runtimeDir: rt, x11Display: _env['DISPLAY']);
      }
      return null;
    }

    DisplayEnvironment? x11() {
      final d = _env['DISPLAY'] ?? _findX11Display();
      if (d == null || d.isEmpty) return null;
      return DisplayEnvironment(DisplayKind.x11, x11Display: d, runtimeDir: rt, xauthority: _xauth);
    }

    switch (mode) {
      case 'wayland':
        return wayland() ?? DisplayEnvironment(DisplayKind.wayland, waylandDisplay: 'wayland-0', runtimeDir: rt);
      case 'x11':
        return x11() ?? DisplayEnvironment(DisplayKind.x11, x11Display: ':0', runtimeDir: rt, xauthority: _xauth);
    }
    return wayland() ?? x11() ?? DisplayEnvironment(DisplayKind.none, runtimeDir: rt);
  }
}

/// Logical size of the TV output in CSS/DIP pixels (mode / scale, rotated
/// by the transform), which is what a fullscreen Chromium window covers.
class OutputSize {
  const OutputSize(this.width, this.height);
  final int width;
  final int height;

  @override
  bool operator ==(Object other) => other is OutputSize && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash(width, height);
  @override
  String toString() => '${width}x$height';
}

/// Parses `wlr-randr` text output (labwc, wayfire, sway...). Picks the
/// enabled output at position 0,0 (else the first enabled one).
OutputSize? parseWlrRandr(String text) {
  final outputs = <Map<String, Object?>>[];
  Map<String, Object?>? cur;
  var inModes = false;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    if (raw.trim().isEmpty) continue;
    if (!raw.startsWith(' ') && !raw.startsWith('\t')) {
      cur = {'enabled': true, 'scale': 1.0, 'transform': 'normal', 'pos': '0,0'};
      outputs.add(cur);
      inModes = false;
      continue;
    }
    if (cur == null) continue;
    final line = raw.trim();
    final kv = RegExp(r'^([A-Za-z ]+):\s*(.*)$').firstMatch(line);
    if (kv != null && !RegExp(r'^\d').hasMatch(line)) {
      final key = kv.group(1)!.toLowerCase();
      final value = kv.group(2)!.trim();
      inModes = key == 'modes';
      switch (key) {
        case 'enabled':
          cur['enabled'] = value == 'yes';
        case 'scale':
          cur['scale'] = double.tryParse(value) ?? 1.0;
        case 'transform':
          cur['transform'] = value;
        case 'position':
          cur['pos'] = value.replaceAll(' ', '');
      }
      continue;
    }
    if (inModes) {
      final m = RegExp(r'^(\d+)x(\d+) px.*\bcurrent\b').firstMatch(line);
      if (m != null) cur['mode'] = [int.parse(m.group(1)!), int.parse(m.group(2)!)];
    }
  }
  final usable = [
    for (final o in outputs)
      if (o['enabled'] == true && o['mode'] != null) o
  ];
  if (usable.isEmpty) return null;
  final o = usable.firstWhere((o) => o['pos'] == '0,0', orElse: () => usable.first);
  final mode = o['mode']! as List<int>;
  final scale = (o['scale']! as double) <= 0 ? 1.0 : o['scale']! as double;
  var w = (mode[0] / scale).round();
  var h = (mode[1] / scale).round();
  final t = '${o['transform']}';
  if (t.contains('90') || t.contains('270')) {
    final x = w;
    w = h;
    h = x;
  }
  return OutputSize(w, h);
}

/// Parses `xrandr --current`: `Screen 0: minimum ..., current 1920 x 1080, ...`.
OutputSize? parseXrandr(String text) {
  final m = RegExp(r'current (\d+) x (\d+)').firstMatch(text);
  return m == null ? null : OutputSize(int.parse(m.group(1)!), int.parse(m.group(2)!));
}

/// Reads the real output size at runtime (`wlr-randr` on Wayland,
/// `xrandr` on X11). Null when it cannot be determined.
Future<OutputSize?> detectOutputSize(ProcessRunner runner, DisplayEnvironment env) async {
  final childEnv = {...Platform.environment, ...env.childEnvironment};
  Future<String?> out(String exe, List<String> args) async {
    final path = await runner.which(exe);
    if (path == null) return null;
    final r = await runner.run(path, args, environment: childEnv, timeout: const Duration(seconds: 5));
    return r.ok ? r.stdout : null;
  }

  if (env.isWayland) {
    final t = await out('wlr-randr', const []);
    final s = t == null ? null : parseWlrRandr(t);
    if (s != null) return s;
  }
  if (env.isX11 || env.x11Display != null) {
    final t = await out('xrandr', const ['--current']);
    final s = t == null ? null : parseXrandr(t);
    if (s != null) return s;
  }
  return null;
}
