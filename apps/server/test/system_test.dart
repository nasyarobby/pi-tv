import 'dart:io';

import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  setUp(() => Log.capture = true);

  group('DisplayDetector (Wayland first)', () {
    late Directory rt;
    setUp(() => rt = Directory.systemTemp.createTempSync('pitv-rt'));
    tearDown(() => rt.deleteSync(recursive: true));

    test('WAYLAND_DISPLAY wins', () {
      final d =
          DisplayDetector(environment: {'WAYLAND_DISPLAY': 'wayland-1', 'DISPLAY': ':0', 'XDG_RUNTIME_DIR': rt.path})
              .detect();
      expect(d.kind, DisplayKind.wayland);
      expect(d.childEnvironment['WAYLAND_DISPLAY'], 'wayland-1');
      expect(d.childEnvironment['XDG_RUNTIME_DIR'], rt.path);
    });

    test('finds the compositor socket when the service has no session env', () async {
      final s = await ServerSocket.bind(InternetAddress('${rt.path}/wayland-0', type: InternetAddressType.unix), 0);
      File('${rt.path}/wayland-0.lock').writeAsStringSync('');
      final d = DisplayDetector(environment: {'XDG_RUNTIME_DIR': rt.path}, x11SocketDir: '/nonexistent').detect();
      expect(d.kind, DisplayKind.wayland);
      expect(d.waylandDisplay, 'wayland-0');
      await s.close();
    });

    test('Wayland is preferred over an X socket (Xwayland)', () async {
      final s = await ServerSocket.bind(InternetAddress('${rt.path}/wayland-0', type: InternetAddressType.unix), 0);
      final x = Directory.systemTemp.createTempSync('pitv-x');
      File('${x.path}/X0').writeAsStringSync('');
      final d = DisplayDetector(environment: {'XDG_RUNTIME_DIR': rt.path}, x11SocketDir: x.path).detect();
      expect(d.kind, DisplayKind.wayland);
      await s.close();
      x.deleteSync(recursive: true);
    });

    test('X11 fallback from DISPLAY or /tmp/.X11-unix', () {
      expect(
          DisplayDetector(environment: {'DISPLAY': ':1', 'XDG_RUNTIME_DIR': rt.path}).detect().kind, DisplayKind.x11);
      final x = Directory.systemTemp.createTempSync('pitv-x');
      File('${x.path}/X0').writeAsStringSync('');
      final d = DisplayDetector(environment: {'XDG_RUNTIME_DIR': rt.path}, x11SocketDir: x.path).detect();
      expect(d.kind, DisplayKind.x11);
      expect(d.childEnvironment['DISPLAY'], ':0');
      x.deleteSync(recursive: true);
    });

    test('nothing found', () {
      final d = DisplayDetector(environment: {'XDG_RUNTIME_DIR': rt.path}, x11SocketDir: '/nonexistent').detect();
      expect(d.kind, DisplayKind.none);
    });

    test('DISPLAY_MODE forces a kind', () {
      final d = DisplayDetector(environment: {'DISPLAY': ':0', 'XDG_RUNTIME_DIR': rt.path}, mode: 'wayland').detect();
      expect(d.kind, DisplayKind.wayland);
      expect(d.waylandDisplay, 'wayland-0');
    });
  });

  group('screen blank inhibit', () {
    test('Wayland: logind idle lock + pause swayidle, released on release', () async {
      final r = FakeRunner(available: {'systemd-inhibit', 'pkill', 'wlopm'});
      final i = WaylandInhibitor(r, const DisplayEnvironment(DisplayKind.wayland, waylandDisplay: 'wayland-0'));
      await i.acquire();
      expect(i.active, isTrue);
      expect(r.starts.single.args, containsAll(['--what=idle:sleep', 'sleep', 'infinity']));
      expect(r.runs.map((c) => c.toString()), contains(contains('pkill -STOP')));
      expect(r.runs.any((c) => c.exe.endsWith('wlopm') && c.args.contains('--on')), isTrue);
      await i.acquire(); // idempotent
      expect(r.starts, hasLength(1));
      await i.release();
      expect(i.active, isFalse);
      expect(r.processes.single.exited, isTrue, reason: 'systemd-inhibit lock dropped');
      expect(r.runs.map((c) => c.toString()), contains(contains('pkill -CONT')));
      expect(r.runs.any((c) => c.args.contains('--off')), isFalse, reason: 'never blanks the TV itself');
    });

    test('X11: xset s off -dpms, restored on release', () async {
      final r = FakeRunner(available: {'xset'});
      final i = X11Inhibitor(r, const DisplayEnvironment(DisplayKind.x11, x11Display: ':0'));
      await i.acquire();
      expect(r.runs.map((c) => c.args.join(' ')), containsAll(['s off', '-dpms', 's reset']));
      await i.release();
      expect(r.runs.map((c) => c.args.join(' ')), containsAll(['s on', '+dpms']));
    });

    test('AutoInhibitor picks the inhibitor for the detected display', () async {
      final r = FakeRunner(available: {'xset', 'systemd-inhibit', 'pkill'});
      var env = const DisplayEnvironment(DisplayKind.wayland, waylandDisplay: 'wayland-0');
      final a = AutoInhibitor(r, () => env);
      await a.acquire();
      expect(r.starts.single.exe, '/usr/bin/systemd-inhibit');
      await a.release();
      env = const DisplayEnvironment(DisplayKind.x11, x11Display: ':0');
      await a.acquire();
      expect(r.runs.last.exe, '/usr/bin/xset');
      await a.release();
    });
  });

  group('HDMI-CEC', () {
    test('wakes the TV and makes the Pi the active source, never standby', () async {
      final r = FakeRunner(available: {'cec-client'});
      final cec = CecTvControl(r);
      await cec.wakeAndSelect();
      expect(r.runs.map((c) => c.stdinText?.trim()), ['on 0', 'as']);
      expect(r.runs.every((c) => c.args.contains('-s')), isTrue);
      expect(r.runs.any((c) => (c.stdinText ?? '').contains('standby')), isFalse);
    });

    test('debounces rapid plays', () async {
      final r = FakeRunner(available: {'cec-client'});
      final cec = CecTvControl(r);
      await cec.wakeAndSelect();
      await cec.wakeAndSelect();
      expect(r.runs, hasLength(2));
    });

    test('falls back to cec-ctl', () async {
      final r = FakeRunner(available: {'cec-ctl'});
      r.onRun = (c) => CommandResult(0, c.args.contains('--playback') ? 'Physical Address : 2.0.0.0\n' : '', '');
      await CecTvControl(r).wakeAndSelect();
      final lines = r.runs.map((c) => c.args.join(' ')).toList();
      expect(lines, contains(contains('--image-view-on')));
      expect(lines, contains(contains('phys-addr=2.0.0.0')));
      expect(lines.any((l) => l.contains('standby')), isFalse);
    });
  });
}
