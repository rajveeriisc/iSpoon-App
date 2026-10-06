import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';

final t0 = DateTime(2026, 9, 11, 12);
DateTime at(int s) => t0.add(Duration(seconds: s));
BiteEvent bite(int s) => BiteEvent(time: at(s), probability: 0.9);

void main() {
  test('a lone bite is not a meal and expires', () {
    final m = MealTracker()..onBite(bite(0));
    expect(m.phase, MealPhase.idle);
    expect(m.hasPendingBite, isTrue);
    m.tick(at(31));
    expect(m.hasPendingBite, isFalse);
    m.onBite(bite(40));
    expect(m.phase, MealPhase.idle, reason: 'first bite expired');
    m.onBite(bite(50));
    expect(m.phase, MealPhase.eating);
    expect(m.bites.map((b) => b.time), [at(40), at(50)]);
    expect(m.start, at(40));
  });

  test('two bites within 30 s start a meal and both count', () {
    final m = MealTracker()
      ..onBite(bite(0))
      ..onBite(bite(5));
    expect(m.phase, MealPhase.eating);
    expect(m.bites, hasLength(2));
  });

  test('pause after 60 s, resume on the next bite', () {
    final m = MealTracker()
      ..onBite(bite(0))
      ..onBite(bite(5));
    m.tick(at(64));
    expect(m.phase, MealPhase.eating);
    m.tick(at(65));
    expect(m.phase, MealPhase.paused);
    m.onBite(bite(90));
    expect(m.phase, MealPhase.eating);
    expect(m.bites, hasLength(3));
  });

  test('3 min without a bite ends and saves the meal', () {
    final m = MealTracker();
    for (final s in [0, 5, 10, 15]) {
      m.onBite(bite(s));
    }
    // Enough windows to be a reading: below kMinSteadyWindows a share swings
    // between 0 % and 100 %, so steadyPct stays null — see the case below.
    for (var i = 0; i < 4; i++) {
      m.onWindow(rhythmic: false, active: true, hz: 7);
    }
    for (var i = 0; i < 4; i++) {
      m.onWindow(rhythmic: true, active: true, hz: 5);
    }
    final rec = m.tick(at(15 + 180));
    expect(rec, isNotNull);
    expect(rec!.bites, hasLength(4));
    expect(rec.end, at(15), reason: 'a timed-out meal ends at its last bite');
    expect(rec.steadyPct, 50);
    expect(rec.rhythmHz, 5);
    expect(m.phase, MealPhase.finished);
    expect(m.lastMeal, same(rec));
  });

  test('too few steadiness windows is not a reading', () {
    final m = MealTracker();
    for (final s in [0, 5, 10]) {
      m.onBite(bite(s));
    }
    // One window either way would read 0 % or 100 %; the meal must say
    // "not enough to tell" instead, on every screen at once.
    m.onWindow(rhythmic: true, active: true, hz: 5);
    final rec = m.finish(at(20), MealEndReason.userFinished);
    expect(rec, isNotNull);
    expect(rec!.windows, 1);
    expect(rec.steadyPct, isNull);
  });

  test('meals under 3 bites are discarded', () {
    final m = MealTracker()
      ..onBite(bite(0))
      ..onBite(bite(5));
    expect(m.finish(at(20), MealEndReason.userFinished), isNull);
    expect(m.phase, MealPhase.idle);
    expect(m.lastMeal, isNull);
  });

  test('manual finish keeps the finish time', () {
    final m = MealTracker();
    for (final s in [0, 4, 8]) {
      m.onBite(bite(s));
    }
    final rec = m.finish(at(30), MealEndReason.userFinished)!;
    expect(rec.end, at(30));
    expect(rec.reason, MealEndReason.userFinished);
  });

  test('steadiness windows count only during a meal', () {
    final m = MealTracker()..onWindow(rhythmic: true, active: true, hz: 5);
    m
      ..onBite(bite(0))
      ..onBite(bite(5))
      ..onWindow(rhythmic: false, active: true, hz: 8);
    expect(m.windows, 1);
    expect(m.rhythmicWindows, 0);
  });
}
