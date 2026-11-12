import 'dart:io';
import 'dart:math';

import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => Log.capture = true);

  test('defaults: port 8787, bind 0.0.0.0, CEC on', () {
    final c = ServerConfig.fromMap({}, home: '/home/pi');
    expect(c.port, 8787);
    expect(c.bindAddress, '0.0.0.0');
    expect(c.cecEnabled, isTrue);
    expect(c.dataDir, '/home/pi/.pi-tv');
    expect(c.pin, isNull);
  });

  test('env keys', () {
    final c = ServerConfig.fromMap({
      'PORT': '9000',
      'TV_PIN': '012345',
      'MEDIA_DIRS': '/srv/Movies: ~/Videos ::/mnt/usb/',
      'CEC': 'off',
      'CHROMIUM_PATH': '/usr/bin/chromium',
      'MPV_PATH': '/usr/bin/mpv',
    }, home: '/home/pi');
    expect(c.port, 9000);
    expect(c.pin, '012345', reason: 'leading zero kept');
    expect(c.mediaDirs, ['/srv/Movies', '/home/pi/Videos', '/mnt/usb']);
    expect(c.cecEnabled, isFalse);
    expect(c.chromiumPath, '/usr/bin/chromium');
    expect(c.mpvPath, '/usr/bin/mpv');
  });

  test('TV_PIN must be exactly 6 digits', () {
    for (final bad in ['12345', '1234567', 'abcdef', '12 345', '-12345', '12345x']) {
      expect(() => ServerConfig.fromMap({'TV_PIN': bad}), throwsA(isA<ConfigException>()), reason: bad);
    }
    expect(ServerConfig.fromMap({'TV_PIN': '000000'}).pin, '000000');
  });

  test('bad CEC / PORT values are rejected', () {
    expect(() => ServerConfig.fromMap({'CEC': 'maybe'}), throwsA(isA<ConfigException>()));
    expect(() => ServerConfig.fromMap({'PORT': 'x'}), throwsA(isA<ConfigException>()));
  });

  test('config file + env override', () {
    final d = Directory.systemTemp.createTempSync('pitv-cfg');
    final f = File('${d.path}/pi-tv.env')..writeAsStringSync('# comment\nPORT=8800\nTV_PIN="000123"\nexport CEC=off\n');
    final c = ServerConfig.load(configFile: f.path, environment: {'PORT': '8801', 'HOME': '/home/pi'});
    expect(c.port, 8801);
    expect(c.pin, '000123');
    expect(c.cecEnabled, isFalse);
    d.deleteSync(recursive: true);
  });

  group('resolvePin', () {
    late Directory d;
    setUp(() => d = Directory.systemTemp.createTempSync('pitv-pin'));
    tearDown(() => d.deleteSync(recursive: true));

    test('TV_PIN is used as-is', () {
      expect(resolvePin(ServerConfig(pin: '001234', dataDir: d.path)), '001234');
      expect(File('${d.path}/pin').existsSync(), isFalse);
    });

    test('generates a random 6 digit PIN on first start, writes ~/.pi-tv/pin and logs it', () {
      Log.captured.clear();
      final pin = resolvePin(ServerConfig(dataDir: d.path), random: Random(7));
      expect(pin, matches(RegExp(r'^\d{6}$')));
      expect(File('${d.path}/pin').readAsStringSync().trim(), pin);
      expect(Log.captured.any((l) => l.contains(pin)), isTrue);
      final mode = File('${d.path}/pin').statSync().modeString();
      expect(mode, 'rw-------');
      // Second start reuses it.
      expect(resolvePin(ServerConfig(dataDir: d.path)), pin);
    });

    test('an invalid pin file is replaced', () {
      File('${d.path}/pin').writeAsStringSync('1234\n');
      final pin = resolvePin(ServerConfig(dataDir: d.path));
      expect(pin, matches(RegExp(r'^\d{6}$')));
    });
  });
}
