import 'dart:io';

import 'package:pi_tv_server/pi_tv_server.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late FakeRunner runner;
  late FakeMpvConnector conn;
  late MpvPlayer player;
  late Directory tmp;

  setUp(() {
    Log.capture = true;
    tmp = Directory.systemTemp.createTempSync('pitv-mpv');
    runner = FakeRunner(available: {'mpv'});
    conn = FakeMpvConnector();
    runner.onStart = (c, p) {
      conn.available = true;
      // When mpv quits, the process exits.
      conn.onConnect = (ipc) => ipc.onQuit = () => p.exit(0);
    };
    player = MpvPlayer(
      runner: runner,
      display: () => const DisplayEnvironment(DisplayKind.wayland, waylandDisplay: 'wayland-0'),
      socketPath: '${tmp.path}/mpv.sock',
      connector: conn,
    );
  });

  tearDown(() async {
    await player.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('starts mpv fullscreen with hwdec, keep-open, IPC and sidecar subtitles', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    final args = runner.starts.single.args;
    for (final a in [
      '--fullscreen',
      '--hwdec=auto',
      '--keep-open=yes',
      '--input-ipc-server=${tmp.path}/mpv.sock',
      '--sub-auto=fuzzy',
    ]) {
      expect(args, contains(a));
    }
    final cmds = conn.current!.commands;
    expect(cmds, contains(equals(['loadfile', '/media/film.mkv', 'replace'])));
    expect(cmds, contains(equals(['set_property', 'pause', false])));
    expect(player.isOpen, isTrue);
  });

  test('start offset is applied', () async {
    await player.load(const PlayTarget.file('/media/film.mkv', startSeconds: 30));
    expect(conn.current!.commands, contains(equals(['set_property', 'start', '30'])));
  });

  test('eof-reached marks ended and keeps mpv open', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    conn.current!.property('eof-reached', true);
    expect(player.snapshot.ended, isTrue);
    expect(player.isOpen, isTrue);
    expect(conn.current!.commands.any((c) => c.first == 'quit'), isFalse);
  });

  test('Stop pauses on the current frame, does not quit', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    await player.stop();
    expect(conn.current!.commands.last, ['set_property', 'pause', true]);
    expect(conn.current!.commands.any((c) => c.first == 'quit'), isFalse);
    expect(runner.processes.single.exited, isFalse);
  });

  test('next local file reuses the same mpv', () async {
    await player.load(const PlayTarget.file('/media/a.mkv'));
    await player.load(const PlayTarget.file('/media/b.mkv'));
    expect(runner.starts, hasLength(1));
    expect(conn.current!.commands.where((c) => c.first == 'loadfile'), hasLength(2));
  });

  test('controls: seek, volume, mute, subtitles', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    await player.seek(12);
    await player.setVolume(150);
    await player.setMuted(true);
    final subs = await player.toggleSubtitles();
    final cmds = conn.current!.commands;
    expect(cmds, contains(equals(['seek', 12.0, 'absolute'])));
    expect(cmds, contains(equals(['set_property', 'volume', 100])));
    expect(cmds, contains(equals(['set_property', 'mute', true])));
    expect(subs, isFalse);
  });

  test('Close quits mpv', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    final ipc = conn.current!;
    await player.close();
    expect(ipc.commands.last, ['quit']);
    expect(runner.processes.single.exited, isTrue);
    expect(player.isOpen, isFalse);
  });

  test('reuses an mpv left running by a previous server process', () async {
    final sock = await ServerSocket.bind(InternetAddress('${tmp.path}/mpv.sock', type: InternetAddressType.unix), 0);
    conn.available = true;
    await player.load(const PlayTarget.file('/media/film.mkv'));
    expect(runner.starts, isEmpty);
    expect(conn.current!.commands, contains(equals(['loadfile', '/media/film.mkv', 'replace'])));
    await sock.close();
  });
  test('closeIfRunning quits an mpv left on the socket by a previous server run', () async {
    final server = await ServerSocket.bind(InternetAddress('${tmp.path}/mpv.sock', type: InternetAddressType.unix), 0);
    addTearDown(server.close);
    conn.available = true;
    var quit = false;
    conn.onConnect = (ipc) => ipc.onQuit = () => quit = true;
    expect(player.isOpen, isFalse);
    await player.closeIfRunning();
    expect(quit, isTrue);
    expect(runner.starts, isEmpty, reason: 'nothing is launched');
  });

  test('closeIfRunning with nothing running does nothing', () async {
    await player.closeIfRunning();
    expect(conn.connects, 0);
  });

  test('closeIfRunning on our own mpv quits it', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    await player.closeIfRunning();
    expect(player.isOpen, isFalse);
    expect(runner.processes.single.exited, isTrue);
  });

  test('mpv reports the decoded video size', () async {
    await player.load(const PlayTarget.file('/media/film.mkv'));
    conn.current!
      ..property('width', 1920)
      ..property('height', 1080);
    expect([player.snapshot.width, player.snapshot.height], [1920, 1080]);
    expect(conn.current!.commands, contains(equals(['observe_property', 9, 'width'])));
  });
}
