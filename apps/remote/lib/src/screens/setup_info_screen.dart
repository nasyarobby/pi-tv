import 'package:flutter/material.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';

/// `/setup`: server URL + QR for the Android app. Never shows the PIN.
class SetupInfoScreen extends StatefulWidget {
  const SetupInfoScreen({super.key});
  @override
  State<SetupInfoScreen> createState() => _SetupInfoScreenState();
}

class _SetupInfoScreenState extends State<SetupInfoScreen> {
  Future<SetupInfo?>? _info;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _info ??= AppScope.read(context).setupInfo();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up the Android app')),
      body: FutureBuilder<SetupInfo?>(
        future: _info,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final info = snap.data;
          if (info == null) return const Center(child: Text('Could not load the server address.'));
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('In the Pi TV Android app, tap "Scan QR code", then enter the PIN.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: QrImageView(key: const ValueKey('setup-qr'), data: info.url, size: 260),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(info.url,
                  key: const ValueKey('setup-url'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall),
              if (info.candidates.length > 1) ...[
                const SizedBox(height: 16),
                const Text('Other addresses of this Pi:', textAlign: TextAlign.center),
                for (final c in info.candidates.where((c) => c != info.url))
                  SelectableText(c, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 24),
              const Text(
                  'The QR code holds only the address. Keep the PIN to yourself; '
                  'this server is meant for the home network only and should not be port-forwarded.',
                  textAlign: TextAlign.center),
            ],
          );
        },
      ),
    );
  }
}
