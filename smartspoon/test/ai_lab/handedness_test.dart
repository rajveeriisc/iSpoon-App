import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';

void main() {
  test('neutral until three agreeing votes, then right', () {
    final v = HandednessVoter();
    expect(v.mode, HandMode.neutral);
    expect(v.vote(12), isNull);
    expect(v.vote(30), isNull);
    expect(v.vote(8), Hand.right);
    expect(v.mode, HandMode.right);
    expect(v.isVoting, isFalse);
    expect(v.vote(-50), isNull, reason: 'decided hands stop voting');
  });

  test('mixed votes keep voting until the last three agree', () {
    final v = HandednessVoter();
    for (final yaw in [10.0, -5.0, 7.0, -3.0, -9.0]) {
      expect(v.vote(yaw), isNull);
    }
    expect(v.vote(-20), Hand.left);
    expect(v.mode, HandMode.left);
  });

  test('a manual preference overrides detection', () {
    final v = HandednessVoter(
        preference: HandPreference.left, detected: Hand.right);
    expect(v.mode, HandMode.left);
    expect(v.isVoting, isFalse);
    v.preference = HandPreference.auto;
    expect(v.mode, HandMode.right);
    v.resetDetection();
    expect(v.mode, HandMode.neutral);
  });
}
