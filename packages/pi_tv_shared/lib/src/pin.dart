/// PIN format and brute-force protection helpers shared by server and remotes.
library;

import 'dart:math';

/// Number of digits in the shared PIN.
const int pinLength = 6;

final RegExp _pinPattern = RegExp(r'^[0-9]{6}$');

/// True when [pin] is exactly six ASCII digits (`000000`–`999999`).
/// Leading zeros are significant: `012345` is valid, `12345` is not.
bool isValidPin(String? pin) => pin != null && _pinPattern.hasMatch(pin);

/// Generates a random six digit PIN (leading zeros allowed).
String generatePin([Random? random]) {
  final r = random ?? Random.secure();
  return r.nextInt(1000000).toString().padLeft(pinLength, '0');
}

/// Compares two strings in time independent of where they differ.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Tracks failed PIN attempts per client address and locks an address out
/// after [maxAttempts] failures for [lockout].
class PinAttemptLimiter {
  PinAttemptLimiter({
    this.maxAttempts = 5,
    this.lockout = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxAttempts;
  final Duration lockout;
  final DateTime Function() _clock;
  final Map<String, _Attempts> _byAddress = {};

  /// Remaining lock time for [address], or `null` when not locked.
  Duration? lockedFor(String address) {
    final a = _byAddress[address];
    final until = a?.lockedUntil;
    if (until == null) return null;
    final now = _clock();
    if (!now.isBefore(until)) {
      _byAddress.remove(address);
      return null;
    }
    return until.difference(now);
  }

  /// Records a failure; returns true if this failure locked the address.
  bool recordFailure(String address) {
    if (lockedFor(address) != null) return true;
    final a = _byAddress.putIfAbsent(address, _Attempts.new);
    a.failures++;
    if (a.failures >= maxAttempts) {
      a.lockedUntil = _clock().add(lockout);
      return true;
    }
    return false;
  }

  /// Clears the failure count after a successful login.
  void recordSuccess(String address) => _byAddress.remove(address);

  /// Failures recorded for [address] in the current window.
  int failures(String address) => _byAddress[address]?.failures ?? 0;
}

class _Attempts {
  int failures = 0;
  DateTime? lockedUntil;
}
