import 'dart:async';

import 'package:flutter/services.dart';

/// Text shared into the app (Android share sheet / YouTube links).
abstract class ShareSource {
  /// The share that launched the app, if any (consumed once).
  Future<String?> initialShare();

  /// Shares received while the app is running.
  Stream<String> get shares;
}

class NoShareSource implements ShareSource {
  @override
  Future<String?> initialShare() async => null;
  @override
  Stream<String> get shares => const Stream.empty();
}

/// Bridges MainActivity's ACTION_SEND / ACTION_VIEW intents.
class AndroidShareSource implements ShareSource {
  AndroidShareSource() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareReceived' && call.arguments is String) {
        _ctrl.add(call.arguments as String);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('pi_tv/share');
  final _ctrl = StreamController<String>.broadcast();

  @override
  Future<String?> initialShare() async {
    try {
      return await _channel.invokeMethod<String>('getInitialShare');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<String> get shares => _ctrl.stream;
}
