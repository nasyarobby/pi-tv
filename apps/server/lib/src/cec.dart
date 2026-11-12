import 'log.dart';
import 'process.dart';

/// HDMI-CEC: wake the TV and switch it to the Pi's input when playback
/// starts. Never sends standby (Stop/Close leave the TV on).
abstract class TvControl {
  Future<void> wakeAndSelect();
}

class NoopTvControl implements TvControl {
  int calls = 0;
  @override
  Future<void> wakeAndSelect() async => calls++;
}

class CecTvControl implements TvControl {
  CecTvControl(this._runner,
      {this.cecClient = 'cec-client',
      this.cecCtl = 'cec-ctl',
      this.minInterval = const Duration(seconds: 20),
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final ProcessRunner _runner;
  final String cecClient;
  final String cecCtl;
  final Duration minInterval;
  final DateTime Function() _clock;
  final _log = Log('cec');
  DateTime? _last;
  Future<void>? _inFlight;

  @override
  Future<void> wakeAndSelect() {
    final now = _clock();
    if (_last != null && now.difference(_last!) < minInterval) return Future.value();
    _last = now;
    return _inFlight ??= _send().whenComplete(() => _inFlight = null);
  }

  Future<void> _send() async {
    final client = await _runner.which(cecClient);
    if (client != null) {
      // -s: single command then exit; -d 1: errors only.
      for (final cmd in const ['on 0', 'as']) {
        final r =
            await _runner.run(client, ['-s', '-d', '1'], stdinText: '$cmd\n', timeout: const Duration(seconds: 15));
        if (!r.ok) _log.warn('cec-client "$cmd" exit ${r.exitCode}: ${r.stderr.trim()}');
      }
      _log.info('CEC: TV on + active source');
      return;
    }
    final ctl = await _runner.which(cecCtl);
    if (ctl != null) {
      final cfg = await _runner.run(ctl, ['-d', '/dev/cec0', '--playback'], timeout: const Duration(seconds: 10));
      await _runner.run(ctl, ['-d', '/dev/cec0', '--to', '0', '--image-view-on'], timeout: const Duration(seconds: 10));
      final phys = RegExp(r'Physical Address\s*:\s*([0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f])', caseSensitive: false)
          .firstMatch(cfg.stdout)
          ?.group(1);
      if (phys != null && phys != 'f.f.f.f') {
        await _runner.run(ctl, ['-d', '/dev/cec0', '--to', '0', '--active-source', 'phys-addr=$phys'],
            timeout: const Duration(seconds: 10));
      }
      _log.info('CEC (cec-ctl): image view on + active source');
      return;
    }
    _log.warn('CEC enabled but neither cec-client nor cec-ctl was found');
  }
}
