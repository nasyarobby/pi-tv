import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pi_tv_server/pi_tv_server.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c', help: 'KEY=VALUE config file (env vars override it)')
    ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Debug logging')
    ..addFlag('version', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(64);
  }
  if (args['help'] == true) {
    stdout.writeln('pi-tv-server [options]\n\n${parser.usage}\n\n'
        'Environment: PORT, TV_PIN, MEDIA_DIRS, CEC, CHROMIUM_PATH, MPV_PATH, WEB_DIR, DATA_DIR, ...');
    return;
  }
  if (args['version'] == true) {
    stdout.writeln(serverVersion);
    return;
  }
  Log.verbose = args['verbose'] == true;
  final ServerConfig config;
  try {
    config = ServerConfig.load(configFile: args['config'] as String?);
  } on ConfigException catch (e) {
    stderr.writeln(e);
    exit(78); // EX_CONFIG
  }
  final server = PiTvServer(config);
  try {
    await server.start();
  } on ConfigException catch (e) {
    stderr.writeln(e);
    exit(78);
  } on SocketException catch (e) {
    stderr.writeln('Cannot listen on ${config.bindAddress}:${config.port}: $e');
    exit(1);
  }
  final done = Completer<void>();
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  await server.stop();
  exit(0);
}
