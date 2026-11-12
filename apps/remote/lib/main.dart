import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/platform/settings_store.dart';
import 'src/platform/share_source.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final initialRoute = kIsWeb ? Uri.base.path : '/';
  if (kIsWeb) usePathUrlStrategy();
  final controller = AppController(
    store: kIsWeb ? MemorySettingsStore() : SecureSettingsStore(),
    isWeb: kIsWeb,
    webOrigin: kIsWeb ? Uri.parse(Uri.base.origin) : null,
    shareSource: !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? AndroidShareSource() : NoShareSource(),
  );
  controller.init();
  runApp(PiTvApp(controller: controller, initialRoute: initialRoute.isEmpty ? '/' : initialRoute));
}
