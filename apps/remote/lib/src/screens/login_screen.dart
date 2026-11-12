import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../widgets/pin_pad.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _pad = GlobalKey<PinPadState>();
  String? _error;
  bool _busy = false;

  Future<void> _submit(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).login(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
    if (err != null) _pad.currentState?.clear();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.tv, size: 56),
                const SizedBox(height: 12),
                Text('Pi TV', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text('Enter the 6-digit PIN', style: Theme.of(context).textTheme.titleMedium),
                if (!app.isWeb && app.serverUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${app.serverUrl}', style: Theme.of(context).textTheme.bodySmall),
                  ),
                PinPad(key: _pad, onCompleted: _submit, enabled: !_busy),
                SizedBox(
                  height: 48,
                  child: _busy
                      ? const Center(child: CircularProgressIndicator())
                      : Text(_error ?? app.lastError ?? '',
                          key: const ValueKey('login-error'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
                if (!app.isWeb)
                  TextButton.icon(
                    onPressed: _busy ? null : app.changeServer,
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    label: const Text('Change Pi address'),
                  ),
                if (app.pendingShare != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Your shared link will be sent after you log in.'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
