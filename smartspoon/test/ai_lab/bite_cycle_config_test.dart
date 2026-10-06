// The bite-cycle gate ships dark, and its thresholds travel with the model.
//
// Two guarantees are asserted here because both are easy to break silently:
// that shadow mode changes nothing at all, and that the numbers live in the
// model file rather than being re-hardcoded in logic.
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/ai_lab_model.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';

import 'ai_lab_fixtures.dart';

void main() {
  group('thresholds come from the model file', () {
    test('the shipped model ships the gate switched off', () {
      // An untuned gate that silently undercounts meals is worse than the
      // false positives it replaces, so enforcement is off until real
      // verdicts have been reviewed.
      expect(loadModel().biteCycle.enforce, isFalse);
    });

    test('values are read from JSON, not hardcoded', () {
      final m = AiLabModel.parse('''
      {
        "version": 1, "trainedOn": "x", "people": 1, "bites": 1,
        "features": [], "threshold": 0.5, "minGapDecisions": 1,
        "votesToDecide": 1,
        "right":   {"mean":[0],"scale":[1],"coef":[0],"intercept":0},
        "neutral": {"mean":[0],"scale":[1],"coef":[0],"intercept":0},
        "evaluation": {"f1":1,"recall":1,"precision":1},
        "steadiness": {
          "fftSize":128,"hop":64,"bandHz":[4,12],
          "rhythmicShareThreshold":0.5,
          "normalSteadyPctMin":90,"normalSteadyPctMedian":95,
          "syntheticDetection":{}
        },
        "biteCycle": {
          "enforce": true,
          "deltaMinDeg": 55.5,
          "dwellMs": 321,
          "verdictDeadlineSamples": 999
        }
      }''');
      expect(m.biteCycle.enforce, isTrue);
      expect(m.biteCycle.deltaMinDeg, 55.5);
      expect(m.biteCycle.dwellMs, 321);
      expect(m.biteCycle.verdictDeadlineSamples, 999);
      // Unspecified keys fall back to the documented defaults.
      expect(m.biteCycle.plateToleranceDeg,
          const BiteCycleConfig().plateToleranceDeg);
    });

    test('a model file predating the gate still loads', () {
      final m = AiLabModel.parse('''
      {
        "version": 1, "trainedOn": "x", "people": 1, "bites": 1,
        "features": [], "threshold": 0.5, "minGapDecisions": 1,
        "votesToDecide": 1,
        "right":   {"mean":[0],"scale":[1],"coef":[0],"intercept":0},
        "neutral": {"mean":[0],"scale":[1],"coef":[0],"intercept":0},
        "evaluation": {"f1":1,"recall":1,"precision":1},
        "steadiness": {
          "fftSize":128,"hop":64,"bandHz":[4,12],
          "rhythmicShareThreshold":0.5,
          "normalSteadyPctMin":90,"normalSteadyPctMedian":95,
          "syntheticDetection":{}
        }
      }''');
      expect(m.biteCycle.enforce, isFalse);
      expect(m.biteCycle.deltaMinDeg, const BiteCycleConfig().deltaMinDeg);
    });
  });

  group('shadow mode is byte-for-byte the old behaviour', () {
    for (final label in fixtureLabels) {
      test('$label: every proposal still counts', () {
        final model = loadModel();
        expect(model.biteCycle.enforce, isFalse);

        final rows = loadFixture(
            (loadGolden()[label] as Map<String, dynamic>)['file'] as String);
        final engine = EatingEngine(model);
        var reported = 0;
        for (final r in rows) {
          if (feedRowUpdate(engine, r).bite != null) reported++;
        }

        // detectedRows is appended once per detector proposal, before the
        // gate is consulted. In shadow mode the two must be equal: the gate
        // observes and logs, and takes nothing away.
        expect(reported, engine.detectedRows.length);
        expect(reported, greaterThan(0), reason: 'fixture produced no bites');

        // ...and it really did run, so the verdicts are there to review.
        expect(engine.cycleLog, isNotEmpty,
            reason: 'the gate should still be computing verdicts');
      });
    }
  });

  // What the gate actually does to two REAL meals. These numbers were
  // measured, not chosen, and they are the reason enforcement is still off.
  //
  // The first build of this gate rejected 11 of the slow eater's 21 true
  // bites. Three separate causes, each fixed and each guarded here:
  //   - the mouth window was symmetric, but a dwell can only be CONFIRMED
  //     after it starts, and a gentle eater's confirmation lag ran to 159
  //     samples against the brisk eater's 4;
  //   - the dwell mean was accumulated from mid-lift, so a slow deceleration
  //     averaged in a tail of low excursion;
  //   - the excursion threshold was one absolute angle for everybody, and
  //     these two eaters tilt the spoon to 54.8 and 44.4 degrees typically.
  group('measured against the real meals', () {
    ({int proposals, int accepted, double? ref}) run(String label) {
      final rows = loadFixture(
          (loadGolden()[label] as Map<String, dynamic>)['file'] as String);
      final engine = EatingEngine(loadModel());
      for (final r in rows) {
        feedRow(engine, r);
      }
      return (
        proposals: engine.detectedRows.length,
        accepted: engine.cycleLog.where((o) => o.accepted).length,
        ref: engine.excursionReferenceDeg,
      );
    }

    test('the brisk eater loses nothing', () {
      final r = run('typical_eater');
      expect(r.accepted, r.proposals,
          reason: 'every one of this meal\'s bites must survive the gate');
    });

    test('the gentle eater stays inside the golden bite range', () {
      // The replay golden for this meal is 18-22 bites. A gate that drops it
      // below that is undercounting a real meal, which is worse than the
      // false positives it exists to remove.
      final r = run('slow_eater');
      expect(r.accepted, greaterThanOrEqualTo(18),
          reason: 'gate must not push a real meal under the golden range');
      expect(r.accepted, lessThanOrEqualTo(r.proposals));
    });

    test('calibration lands on a different reference per eater', () {
      // The whole point of learning it. If these ever converge to the same
      // number the calibration has stopped doing anything.
      final brisk = run('typical_eater').ref;
      final gentle = run('slow_eater').ref;
      expect(brisk, isNotNull);
      expect(gentle, isNotNull);
      expect(brisk!, greaterThan(gentle! + 5),
          reason: 'the brisk eater tilts the spoon measurably further');
    });
  });
}
