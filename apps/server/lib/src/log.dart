import 'dart:io';

/// Minimal logger writing to stderr (captured by journald under systemd).
class Log {
  Log(this.name, {IOSink? sink}) : _sink = sink;
  final String name;
  final IOSink? _sink;

  static bool verbose = false;

  /// Lines logged by every logger (tests can inspect these).
  static final List<String> captured = [];
  static bool capture = false;

  void _w(String level, String msg) {
    final line = '${DateTime.now().toIso8601String()} $level [$name] $msg';
    if (capture) {
      captured.add(line);
      return;
    }
    (_sink ?? stderr).writeln(line);
  }

  void info(String msg) => _w('INFO ', msg);
  void warn(String msg) => _w('WARN ', msg);
  void error(String msg, [Object? e, StackTrace? st]) =>
      _w('ERROR', e == null ? msg : '$msg: $e${verbose && st != null ? '\n$st' : ''}');
  void debug(String msg) {
    if (verbose) _w('DEBUG', msg);
  }
}
