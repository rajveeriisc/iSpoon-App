// The tremor recordings are a reference, not bite-training data: they say
// what a meal eaten with a tremor looks like, so hand steadiness can be read
// against a known answer.
//
// What they showed is that "steady %" alone undersells the difference. An
// ordinary meal has the odd unsteady window too, mostly a fast 8-10 Hz
// jitter. Counting only unsteady windows whose rhythm is in the tremor band
// (8 Hz and below) leaves ordinary meals at 0-5% and puts the tremor sessions
// at 21% and 45%.
//
// Amplitude was tried as a tremor value and does not work: tremor-band
// rotation was 21-23 deg/s in the tremor sessions and 9.5-23 deg/s in
// ordinary ones, because a brisk scoop lands in the same band.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/eating_engine.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/domain/insights/eating_insights.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/steadiness_card.dart';

import 'ai_lab_fixtures.dart';

/// Replays a raw recorder CSV and returns the meal the engine saved.
MealRecord? _meal(String csv) {
  final lines = const LineSplitter().convert(csv);
  final h = lines.first.split(',');
  final iT = h.indexOf('timestamp_ms'),
      iA = h.indexOf('accelX'),
      iG = h.indexOf('gyroX');
  final e = EatingEngine(loadModel());
  var last = 0;
  for (final l in lines.skip(1)) {
    final p = l.split(',');
    if (p.length <= iG + 2) continue;
    last = int.parse(p[iT]);
    e.feed(
        tsMs: last,
        ax: double.parse(p[iA]),
        ay: double.parse(p[iA + 1]),
        az: double.parse(p[iA + 2]),
        gx: double.parse(p[iG]),
        gy: double.parse(p[iG + 1]),
        gz: double.parse(p[iG + 2]));
  }
  return e.tick(DateTime.fromMillisecondsSinceEpoch(last)
      .add(const Duration(minutes: 4)));
}

String _gz(String name) => utf8
    .decode(gzip.decode(File('test/fixtures/ai_lab/$name').readAsBytesSync()));

void main() {
  group('a meal eaten with a tremor reads as one', () {
    for (final f in ['tremor_eating_1.csv.gz', 'tremor_eating_2.csv.gz']) {
      test(f, () {
        final meal = _meal(_gz(f))!;
        // ignore: avoid_print
        print('  $f  steady ${meal.steadyPct!.toStringAsFixed(0)}%  '
            'tremor-like ${meal.tremorPct!.toStringAsFixed(0)}% '
            'at ${meal.tremorHz!.toStringAsFixed(1)} Hz');
        expect(tremorLevelOf(meal.tremorPct!), TremorLevel.marked);
        expect(meal.tremorHz!, inInclusiveRange(4.0, 8.0));
        expect(meal.steadyPct!, lessThan(kShakyBelowPct));
      });
    }
  });

  group('an ordinary meal does not', () {
    test('every labelled ordinary session on disk', () {
      final dir = Directory('/Users/beeslabrajveer/Desktop/bites');
      if (!dir.existsSync()) return;
      final worst = <double>[];
      for (final f in dir.listSync().whereType<File>().where(
          (f) => f.path.split('/').last.startsWith('spoon_session'))) {
        final meal = _meal(f.readAsStringSync());
        expect(meal, isNotNull, reason: f.path);
        worst.add(meal!.tremorPct!);
        expect(tremorLevelOf(meal.tremorPct!), TremorLevel.none,
            reason: '${f.path} read ${meal.tremorPct}% tremor-like');
      }
      worst.sort();
      // ignore: avoid_print
      print('  ${worst.length} ordinary sessions, tremor-like % from '
          '${worst.first.toStringAsFixed(0)} to '
          '${worst.last.toStringAsFixed(0)}');
    });

    test('non-eating movement records no meal to put a reading on', () {
      for (final f in ['non_eating_1.csv.gz', 'non_eating_2.csv.gz']) {
        expect(_meal(_gz(f)), isNull);
      }
    });
  });

  group('the reading itself', () {
    test('needs the same minimum evidence as steadiness', () {
      expect(tremorPctOf(kMinSteadyWindows - 1, 2), isNull);
      expect(tremorPctOf(10, 0), 0);
      expect(tremorPctOf(40, 10), 25);
      expect(tremorPctOf(10, 99), 100, reason: 'cannot exceed the windows');
    });

    test('levels follow the labelled recordings', () {
      // Ordinary meals measured 0-5, tremor meals 21 and 45.
      for (final ordinary in [0.0, 1.0, 2.0, 5.0]) {
        expect(tremorLevelOf(ordinary), TremorLevel.none);
      }
      expect(tremorLevelOf(10), TremorLevel.some);
      for (final tremor in [21.0, 45.0]) {
        expect(tremorLevelOf(tremor), TremorLevel.marked);
      }
    });

    test('tremor-like is never more than unsteady', () {
      // It is the unsteady windows restricted by rhythm, so a meal cannot be
      // more tremulous than it is unsteady.
      for (final f in ['tremor_eating_1.csv.gz', 'tremor_eating_2.csv.gz']) {
        final meal = _meal(_gz(f))!;
        expect(meal.tremorWindows, lessThanOrEqualTo(meal.rhythmicWindows));
      }
    });
  });

  testWidgets('the card states how much of the meal and at what rhythm',
      (tester) async {
    Future<void> pump(MealMetrics m) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SteadinessCard(
                metrics: m,
                reference: loadModel().steadiness,
                live: false,
                rhythmicNow: false,
              ),
            ),
          ),
        ));

    await pump(const MealMetrics(
      bites: 20,
      duration: Duration(minutes: 2),
      steadyPct: 55,
      rhythmHz: 6.2,
      tremorPct: 45,
      tremorHz: 6.2,
    ));
    expect(find.text('Marked tremor-like shaking'), findsOneWidget);
    expect(find.text('45% of this meal, around 6.2 Hz.'), findsOneWidget);

    await pump(const MealMetrics(
      bites: 20,
      duration: Duration(minutes: 2),
      steadyPct: 100,
      tremorPct: 0,
    ));
    expect(find.text('No tremor-like shaking'), findsOneWidget);
    expect(find.text('None of this meal.'), findsOneWidget);
  });
}
