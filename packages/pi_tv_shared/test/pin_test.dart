import 'dart:math';

import 'package:pi_tv_shared/pi_tv_shared.dart';
import 'package:test/test.dart';

void main() {
  group('isValidPin', () {
    test('accepts six digits including leading zeros', () {
      for (final p in ['000000', '012345', '999999', '123456', '000001']) {
        expect(isValidPin(p), isTrue, reason: p);
      }
    });
    test('rejects anything that is not exactly six digits', () {
      for (final p in [
        null,
        '',
        '12345',
        '1234567',
        '12345a',
        ' 12345',
        '123 45',
        '12-345',
        '１２３４５６',
        '+12345',
        '12345\n'
      ]) {
        expect(isValidPin(p), isFalse, reason: '$p');
      }
    });
  });

  test('generatePin is six digits and keeps leading zeros', () {
    // A Random seeded so the first value is small enough to need padding.
    final fake = _FixedRandom(42);
    expect(generatePin(fake), '000042');
    final r = Random(1);
    for (var i = 0; i < 1000; i++) {
      expect(isValidPin(generatePin(r)), isTrue);
    }
  });

  test('constantTimeEquals', () {
    expect(constantTimeEquals('012345', '012345'), isTrue);
    expect(constantTimeEquals('012345', '12345'), isFalse);
    expect(constantTimeEquals('012345', '012346'), isFalse);
  });

  group('PinAttemptLimiter', () {
    test('locks an address after 5 failures for 5 minutes', () {
      var now = DateTime(2026, 1, 1, 12);
      final l = PinAttemptLimiter(clock: () => now);
      for (var i = 0; i < 4; i++) {
        expect(l.recordFailure('10.0.0.2'), isFalse);
      }
      expect(l.lockedFor('10.0.0.2'), isNull);
      expect(l.recordFailure('10.0.0.2'), isTrue);
      expect(l.lockedFor('10.0.0.2'), const Duration(minutes: 5));
      // Other addresses are unaffected.
      expect(l.lockedFor('10.0.0.3'), isNull);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(l.lockedFor('10.0.0.2'), isNotNull);
      now = now.add(const Duration(seconds: 1));
      expect(l.lockedFor('10.0.0.2'), isNull);
      expect(l.failures('10.0.0.2'), 0);
    });
    test('success resets the counter', () {
      final l = PinAttemptLimiter();
      l.recordFailure('a');
      l.recordFailure('a');
      l.recordSuccess('a');
      expect(l.failures('a'), 0);
    });
  });
}

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}
