import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A started child process (real or fake).
abstract class RunningProcess {
  int get pid;
  Future<int> get exitCode;
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
  IOSink get stdin;
}

class CommandResult {
  const CommandResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

/// Seam over `dart:io` processes so players, CEC, ffprobe and the screen
/// inhibitor can be faked in tests.
abstract class ProcessRunner {
  Future<CommandResult> run(String executable, List<String> args,
      {Map<String, String>? environment, String? stdinText, Duration timeout = const Duration(seconds: 30)});

  Future<RunningProcess> start(String executable, List<String> args, {Map<String, String>? environment});

  /// Resolves [name] on PATH (or returns it if it is an existing path).
  Future<String?> which(String name);
}

class IoRunningProcess implements RunningProcess {
  IoRunningProcess(this._p, {void Function(String line)? onOutput}) {
    final out = onOutput;
    if (out != null) {
      _p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(out);
      _p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(out);
    } else {
      _p.stdout.drain<void>();
      _p.stderr.drain<void>();
    }
  }
  final Process _p;
  @override
  int get pid => _p.pid;
  @override
  Future<int> get exitCode => _p.exitCode;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => _p.kill(signal);
  @override
  IOSink get stdin => _p.stdin;
}

class IoProcessRunner implements ProcessRunner {
  IoProcessRunner({this.onOutput});

  /// Receives child stdout/stderr lines of started processes (for logging).
  final void Function(String exe, String line)? onOutput;

  @override
  Future<CommandResult> run(String executable, List<String> args,
      {Map<String, String>? environment, String? stdinText, Duration timeout = const Duration(seconds: 30)}) async {
    final p = await Process.start(executable, args, environment: environment);
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    if (stdinText != null) p.stdin.write(stdinText);
    await p.stdin.close();
    final code = await p.exitCode.timeout(timeout, onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
    return CommandResult(code, await out, await err);
  }

  @override
  Future<RunningProcess> start(String executable, List<String> args, {Map<String, String>? environment}) async {
    final p = await Process.start(executable, args, environment: environment);
    final cb = onOutput;
    return IoRunningProcess(p, onOutput: cb == null ? null : (l) => cb(executable, l));
  }

  @override
  Future<String?> which(String name) async {
    if (name.contains('/')) return File(name).existsSync() ? name : null;
    for (final dir in (Platform.environment['PATH'] ?? '/usr/bin:/bin').split(':')) {
      final f = File('$dir/$name');
      if (f.existsSync()) return f.path;
    }
    return null;
  }
}
