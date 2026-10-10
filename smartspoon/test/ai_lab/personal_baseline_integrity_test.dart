// Three ways the personal baseline could describe the wrong thing.
//
//   1. The wrong PERSON. Profiles were saved under one key for the whole
//      phone, so a second account using the same spoon inherited the first
//      account's "usual pace".
//   2. The wrong MOMENT. A finished meal was compared with a baseline that
//      had already absorbed it, which shrinks every deviation — at meal #7 a
//      meal four standard deviations fast read 1.93 against a limit of 2.0.
//   3. The wrong SAMPLE. Six meals unlocked personalisation even when all six
//      were recorded in one sitting.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartspoon/features/ai_lab/domain/services/personalized_eating_model.dart';

const _legacyKey = 'personalized_eating_model_v1';

/// [n] ordinary meals, one per day, alternating 10 and 14 bites/min: a person
/// whose usual pace is 12 with a spread of 2.
Future<void> _history(PersonalizedEatingModel m, int n,
    {bool sameDay = false}) async {
  for (var i = 0; i < n; i++) {
    await m.recordMeal(
      spoonKey: 's',
      bites: 30,
      paceBpm: i.isEven ? 10 : 14,
      durationMinutes: 10,
      tremor: 0,
      at: sameDay
          ? DateTime(2026, 1, 1, 9).add(Duration(minutes: 20 * i))
          : DateTime(2026, 1, 1).add(Duration(days: i)),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var uid = '';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    uid = 'alice';
    PersonalizedEatingModel.userIdProvider = () => uid;
    PersonalizedEatingModel().resetForTest();
  });

  group('the baseline belongs to the account, not the phone', () {
    test('a second account on the same spoon starts from nothing', () async {
      final m = PersonalizedEatingModel();
      await m.load();
      await _history(m, 8);
      expect(m.profileFor('s')!.mealCount, 8);

      uid = 'bob';
      await m.reloadForUser();
      expect(m.profileFor('s'), isNull,
          reason: "bob was handed alice's usual pace");

      uid = 'alice';
      await m.reloadForUser();
      expect(m.profileFor('s')!.mealCount, 8,
          reason: "alice's own history must survive bob signing in");
    });

    test('the old shared copy is adopted once, then gone', () async {
      SharedPreferences.setMockInitialValues({
        _legacyKey: jsonEncode({
          's': {'spoonKey': 's', 'mealCount': 9, 'avgPaceBpm': 12.0},
        }),
      });
      final m = PersonalizedEatingModel()..resetForTest();
      await m.load();
      expect(m.profileFor('s')!.mealCount, 9,
          reason: 'an existing user must not lose their history on update');

      // If the shared copy were left behind, the next account would adopt it.
      uid = 'bob';
      await m.reloadForUser();
      expect(m.profileFor('s'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_legacyKey), isNull);
    });

    test('a profile saved before days were counted stays personalised',
        () async {
      SharedPreferences.setMockInitialValues({
        _legacyKey: jsonEncode({
          's': {
            'spoonKey': 's',
            'mealCount': 12,
            'avgPaceBpm': 12.0,
            'paceVar': 4.0,
          },
        }),
      });
      final m = PersonalizedEatingModel()..resetForTest();
      await m.load();
      expect(m.profileFor('s')!.canPersonalize, isTrue,
          reason: 'an update must not send a personalised user back to '
              '"learning"');
    });
  });

  group('a meal is judged against the baseline it did not change', () {
    test('at meal 7, a 4-sigma meal is flagged — it used to read as usual',
        () async {
      final m = PersonalizedEatingModel();
      await m.load();
      await _history(m, 6);
      final p = m.profileFor('s')!;
      final fast = p.avgPaceBpm + 4.0 * p.paceStd;

      await m.recordMeal(
        spoonKey: 's',
        bites: 30,
        paceBpm: fast,
        durationMinutes: 10,
        tremor: 0,
        mealUuid: 'meal-7',
        at: DateTime(2026, 1, 20),
      );

      // What the screens used to do: ask again after the update.
      final after = m.judgeMeal('s', paceBpm: fast)!;
      expect(after.verdict, PaceVerdict.usual,
          reason: 'documents the bias: if this now flags, the stored verdict '
              'is no longer what makes the difference');

      final stored = m.profileFor('s')!.judgementFor('meal-7');
      expect(stored, isNotNull);
      expect(stored!.z, closeTo(4.0, 0.05));
      expect(stored.verdict, PaceVerdict.faster);
    });

    test('the verdict is only handed out for the meal it was taken on',
        () async {
      final m = PersonalizedEatingModel();
      await m.load();
      await _history(m, 7);
      await m.recordMeal(
        spoonKey: 's',
        bites: 30,
        paceBpm: 12,
        durationMinutes: 10,
        tremor: 0,
        mealUuid: 'latest',
        at: DateTime(2026, 2, 1),
      );
      final p = m.profileFor('s')!;
      expect(p.judgementFor('latest'), isNotNull);
      expect(p.judgementFor('some-older-meal'), isNull);
      expect(p.judgementFor(null), isNull);
    });

    test('the verdict survives a restart', () async {
      final m = PersonalizedEatingModel();
      await m.load();
      await _history(m, 7);
      await m.recordMeal(
        spoonKey: 's',
        bites: 30,
        paceBpm: 30,
        durationMinutes: 10,
        tremor: 0,
        mealUuid: 'm',
        at: DateTime(2026, 2, 1),
      );
      final z = m.profileFor('s')!.lastZ;
      await m.reloadForUser();
      expect(m.profileFor('s')!.judgementFor('m')!.z, z);
    });
  });

  group('one sitting is not a baseline', () {
    test('six meals in a morning do not unlock personalisation', () async {
      final m = PersonalizedEatingModel();
      await m.load();
      await _history(m, 8, sameDay: true);
      final p = m.profileFor('s')!;
      expect(p.mealCount, 8);
      expect(p.distinctDays, 1);
      expect(p.canPersonalize, isFalse);
      expect(m.judgeMeal('s', paceBpm: 40), isNull,
          reason: 'no verdict without a baseline worth the name');
      expect(m.personalizedTip('s'), contains('day'),
          reason: 'it must say what is actually missing');
    });

    test('the same meals over several days do', () async {
      final m = PersonalizedEatingModel();
      await m.load();
      await _history(m, 8);
      expect(m.profileFor('s')!.distinctDays, 8);
      expect(m.profileFor('s')!.canPersonalize, isTrue);
    });
  });
}
