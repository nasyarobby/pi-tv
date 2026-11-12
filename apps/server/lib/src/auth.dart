import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pi_tv_shared/pi_tv_shared.dart';

import 'config.dart';
import 'log.dart';
import 'store.dart';

/// Returns the PIN to use: `TV_PIN` if set, else `<dataDir>/pin`, else a
/// newly generated random 6 digit PIN written to `<dataDir>/pin` (0600)
/// and printed to the log.
String resolvePin(ServerConfig config, {Random? random, Log? log}) {
  final l = log ?? Log('auth');
  final configured = config.pin;
  if (configured != null) {
    if (!isValidPin(configured)) throw ConfigException('TV_PIN must be exactly 6 digits');
    return configured;
  }
  final file = File(p.join(config.dataDir, 'pin'));
  if (file.existsSync()) {
    final existing = file.readAsStringSync().trim();
    if (isValidPin(existing)) {
      l.info('using PIN from ${file.path}');
      return existing;
    }
    l.warn('${file.path} does not hold a 6 digit PIN; generating a new one');
  }
  final pin = generatePin(random);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$pin\n');
  try {
    Process.runSync('chmod', ['600', file.path]);
  } catch (_) {}
  l.info('No TV_PIN set. Generated PIN: $pin (saved to ${file.path})');
  return pin;
}

/// Session tokens (web cookie and Android bearer token). Only SHA-256
/// hashes are kept on disk.
class SessionStore {
  SessionStore(
      {JsonStore? store, this.lifetime = const Duration(days: 180), DateTime Function()? clock, Random? random})
      : _store = store ?? JsonStore(null),
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure() {
    final d = _store.read();
    if (d is Map) {
      d.forEach((k, v) {
        final exp = DateTime.tryParse('$v');
        if (k is String && exp != null) _sessions[k] = exp;
      });
    }
  }

  final JsonStore _store;
  final Duration lifetime;
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, DateTime> _sessions = {};

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  ({String token, DateTime expiresAt}) create() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    final exp = _clock().add(lifetime);
    _sessions[_hash(token)] = exp;
    _prune();
    _save();
    return (token: token, expiresAt: exp);
  }

  bool validate(String? token) {
    if (token == null || token.isEmpty) return false;
    final exp = _sessions[_hash(token)];
    if (exp == null) return false;
    if (_clock().isAfter(exp)) {
      _sessions.remove(_hash(token));
      _save();
      return false;
    }
    return true;
  }

  void revoke(String token) {
    if (_sessions.remove(_hash(token)) != null) _save();
  }

  void _prune() {
    final now = _clock();
    _sessions.removeWhere((_, exp) => now.isAfter(exp));
  }

  void _save() => _store.write({for (final e in _sessions.entries) e.key: e.value.toUtc().toIso8601String()});
}

sealed class LoginOutcome {}

class LoginOk extends LoginOutcome {
  LoginOk(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;
}

class LoginRejected extends LoginOutcome {
  LoginRejected(this.attemptsLeft);
  final int attemptsLeft;
}

class LoginLockedOut extends LoginOutcome {
  LoginLockedOut(this.retryAfter);
  final Duration retryAfter;
}

class AuthService {
  AuthService({required this.pin, required this.sessions, PinAttemptLimiter? limiter})
      : limiter = limiter ?? PinAttemptLimiter();
  final String pin;
  final SessionStore sessions;
  final PinAttemptLimiter limiter;
  final _log = Log('auth');

  LoginOutcome login(String? candidate, String address) {
    final locked = limiter.lockedFor(address);
    if (locked != null) return LoginLockedOut(locked);
    if (isValidPin(candidate) && constantTimeEquals(candidate!, pin)) {
      limiter.recordSuccess(address);
      final s = sessions.create();
      _log.info('login ok from $address');
      return LoginOk(s.token, s.expiresAt);
    }
    final nowLocked = limiter.recordFailure(address);
    if (nowLocked) {
      _log.warn('too many failed PIN attempts from $address; locked for ${limiter.lockout.inMinutes} min');
      return LoginLockedOut(limiter.lockedFor(address) ?? limiter.lockout);
    }
    return LoginRejected(limiter.maxAttempts - limiter.failures(address));
  }
}
