import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the remote keeps the server URL and session token.
abstract class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

const kServerUrl = 'server_url';
const kToken = 'session_token';

/// Android: flutter_secure_storage (Keystore-backed).
class SecureSettingsStore implements SettingsStore {
  SecureSettingsStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _s.delete(key: key) : _s.write(key: key, value: value);
}

/// Web (session lives in the HTTP-only cookie) and tests.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
