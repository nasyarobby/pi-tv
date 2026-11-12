import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'qr_scan_screen.dart';

/// Android first run: scan the QR code from the Pi's /setup page, or type
/// the address. The PIN is entered on the next screen (never in the QR).
class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});
  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _connect(String text) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).setServer(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (v == null || !mounted) return;
    _ctrl.text = v;
    await _connect(v);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to your Pi')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('On a computer, open the Pi TV web remote and go to Setup to see a QR code, '
                'or type the Pi\'s address below.'),
            const SizedBox(height: 24),
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner, size: 28),
                label: const Text('Scan QR code', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              key: const ValueKey('server-address'),
              controller: _ctrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Pi address',
                hintText: '192.168.1.20:8787',
                border: OutlineInputBorder(),
              ),
              onSubmitted: _busy ? null : _connect,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: FilledButton.tonal(
                key: const ValueKey('server-connect'),
                onPressed: _busy ? null : () => _connect(_ctrl.text),
                child:
                    _busy ? const CircularProgressIndicator() : const Text('Connect', style: TextStyle(fontSize: 18)),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (AppScope.of(context).pendingShare != null)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text('Finish setup and your shared link will be sent to the TV.'),
              ),
          ],
        ),
      ),
    );
  }
}
