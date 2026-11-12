import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_scope.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/server_setup_screen.dart';
import 'screens/setup_info_screen.dart';
import 'theme.dart';

class PiTvApp extends StatelessWidget {
  const PiTvApp({super.key, required this.controller, this.initialRoute = '/'});
  final AppController controller;
  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    final theme = buildPiTvTheme();
    return AppScope(
      controller: controller,
      child: MaterialApp(
        title: 'Pi TV',
        debugShowCheckedModeBanner: false,
        theme: theme,
        initialRoute: initialRoute,
        onGenerateRoute: (settings) {
          final name = settings.name ?? '/';
          final Widget page;
          if (name == '/setup') {
            page = const _Gate(child: SetupInfoScreen());
          } else {
            final tab = homeTabs.indexOf(name);
            page = _Gate(child: HomeScreen(initialTab: tab < 0 ? 0 : tab));
          }
          return MaterialPageRoute(settings: settings, builder: (_) => page);
        },
      ),
    );
  }
}

/// Shows setup / login until the app has a session, then [child].
class _Gate extends StatelessWidget {
  const _Gate({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return switch (app.phase) {
      AppPhase.starting => const Scaffold(body: Center(child: CircularProgressIndicator())),
      AppPhase.needsServer => const ServerSetupScreen(),
      AppPhase.needsLogin => const LoginScreen(),
      AppPhase.ready => child,
    };
  }
}
