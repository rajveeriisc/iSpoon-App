import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/core/services/sync_restore_policy.dart';

void main() {
  group('mealNeedsDedicatedBiteFetch', () {
    test('falls back when bites are omitted', () {
      expect(mealNeedsDedicatedBiteFetch(null, totalBites: 10), isTrue);
    });

    test('trusts a short complete embed', () {
      expect(
        mealNeedsDedicatedBiteFetch(List<int>.filled(39, 0), totalBites: 39),
        isFalse,
      );
    });

    test('pages when the embed hits the 500-row cap', () {
      expect(
        mealNeedsDedicatedBiteFetch(
          List<int>.filled(500, 0),
          totalBites: 500,
        ),
        isTrue,
      );
    });

    test('pages when embed is shorter than reported total_bites', () {
      expect(
        mealNeedsDedicatedBiteFetch(List<int>.filled(20, 0), totalBites: 61),
        isTrue,
      );
    });
  });
}
