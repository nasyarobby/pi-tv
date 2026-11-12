import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_tv_shared/pi_tv_shared.dart';

class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => 'Config error: $message';
}

/// Server configuration from an optional `KEY=VALUE` file plus environment
/// variables (environment wins).
class ServerConfig {
  ServerConfig({
    this.port = 8787,
    this.bindAddress = '0.0.0.0',
    this.pin,
    this.mediaDirs = const [],
    this.cecEnabled = true,
    this.chromiumPath,
    this.mpvPath,
    this.mpvExtraArgs = const [],
    this.ffprobePath = 'ffprobe',
    this.ffmpegPath = 'ffmpeg',
    this.cecClientPath = 'cec-client',
    required this.dataDir,
    this.webDir,
    this.cdpPort = 9333,
    this.inhibit = true,
    this.publicUrl,
    this.displayMode = 'auto',
  });

  final int port;
  final String bindAddress;

  /// The configured 6 digit PIN (`TV_PIN`), or null to use/generate the
  /// one stored in `<dataDir>/pin`.
  final String? pin;
  final List<String> mediaDirs;
  final bool cecEnabled;
  final String? chromiumPath;
  final String? mpvPath;

  /// Extra mpv flags (`MPV_EXTRA_ARGS`, space separated).
  final List<String> mpvExtraArgs;
  final String ffprobePath;
  final String ffmpegPath;
  final String cecClientPath;

  /// State directory, default `~/.pi-tv`.
  final String dataDir;

  /// Directory of the Flutter web build served at `/`.
  final String? webDir;

  /// Chromium remote debugging port (bound to 127.0.0.1 by Chromium).
  final int cdpPort;

  /// Inhibit screen blanking while playing.
  final bool inhibit;

  /// Optional URL to show in the QR code instead of the detected LAN URL.
  final String? publicUrl;

  /// `auto`, `wayland` or `x11`.
  final String displayMode;

  static const keys = {
    'PORT',
    'BIND',
    'TV_PIN',
    'MEDIA_DIRS',
    'CEC',
    'CHROMIUM_PATH',
    'MPV_PATH',
    'MPV_EXTRA_ARGS',
    'FFPROBE_PATH',
    'FFMPEG_PATH',
    'CEC_CLIENT_PATH',
    'DATA_DIR',
    'WEB_DIR',
    'CDP_PORT',
    'INHIBIT',
    'PUBLIC_URL',
    'DISPLAY_MODE',
  };

  /// Parses `KEY=VALUE` lines; `#` comments and blank lines are ignored,
  /// values may be wrapped in single or double quotes.
  static Map<String, String> parseEnvFile(String content) {
    final out = <String, String>{};
    for (var line in content.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ')) line = line.substring(7).trim();
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final k = line.substring(0, eq).trim();
      var v = line.substring(eq + 1).trim();
      if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
        v = v.substring(1, v.length - 1);
      }
      out[k] = v;
    }
    return out;
  }

  static bool _bool(String? v, bool def, String key) {
    if (v == null || v.isEmpty) return def;
    switch (v.toLowerCase()) {
      case 'on' || 'true' || '1' || 'yes':
        return true;
      case 'off' || 'false' || '0' || 'no':
        return false;
    }
    throw ConfigException('$key must be on or off, got "$v"');
  }

  static int _int(String? v, int def, String key) {
    if (v == null || v.isEmpty) return def;
    final n = int.tryParse(v);
    if (n == null || n <= 0 || n > 65535) throw ConfigException('$key must be a port number, got "$v"');
    return n;
  }

  /// Builds the config from [env] (normally merged file + process env).
  factory ServerConfig.fromMap(Map<String, String> env, {String? home}) {
    String? s(String k) {
      final v = env[k]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    final h = home ?? env['HOME'] ?? Platform.environment['HOME'] ?? '/tmp';
    final pin = s('TV_PIN');
    if (pin != null && !isValidPin(pin)) {
      throw ConfigException('TV_PIN must be exactly 6 digits (000000-999999)');
    }
    final dirs = (s('MEDIA_DIRS') ?? '')
        .split(':')
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .map((d) => d.startsWith('~/') ? p.join(h, d.substring(2)) : d)
        .map(p.normalize)
        .toList();
    final displayMode = (s('DISPLAY_MODE') ?? 'auto').toLowerCase();
    if (!const {'auto', 'wayland', 'x11'}.contains(displayMode)) {
      throw ConfigException('DISPLAY_MODE must be auto, wayland or x11');
    }
    return ServerConfig(
      port: _int(s('PORT'), 8787, 'PORT'),
      bindAddress: s('BIND') ?? '0.0.0.0',
      pin: pin,
      mediaDirs: dirs,
      cecEnabled: _bool(s('CEC'), true, 'CEC'),
      chromiumPath: s('CHROMIUM_PATH'),
      mpvPath: s('MPV_PATH'),
      mpvExtraArgs: (s('MPV_EXTRA_ARGS') ?? '').split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList(),
      ffprobePath: s('FFPROBE_PATH') ?? 'ffprobe',
      ffmpegPath: s('FFMPEG_PATH') ?? 'ffmpeg',
      cecClientPath: s('CEC_CLIENT_PATH') ?? 'cec-client',
      dataDir: s('DATA_DIR') ?? p.join(h, '.pi-tv'),
      webDir: s('WEB_DIR'),
      cdpPort: _int(s('CDP_PORT'), 9333, 'CDP_PORT'),
      inhibit: _bool(s('INHIBIT'), true, 'INHIBIT'),
      publicUrl: s('PUBLIC_URL'),
      displayMode: displayMode,
    );
  }

  /// Loads [configFile] (if it exists) and overlays [environment].
  static ServerConfig load({String? configFile, Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final merged = <String, String>{};
    final file = configFile ?? env['PI_TV_CONFIG'];
    if (file != null) {
      final f = File(file);
      if (!f.existsSync()) throw ConfigException('config file not found: $file');
      merged.addAll(parseEnvFile(f.readAsStringSync()));
    }
    for (final k in keys) {
      final v = env[k];
      if (v != null) merged[k] = v;
    }
    merged['HOME'] = env['HOME'] ?? '/tmp';
    return ServerConfig.fromMap(merged);
  }
}
