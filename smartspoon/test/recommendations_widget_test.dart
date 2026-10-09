// The suggestions card must render what the engine produced and nothing else.
//
// It previously printed two fixed sentences — "Great progress! Tremor
// decreased this week." and an eating-speed tip — whatever the person had
// done, while its doc comment claimed they were derived from recent trends.
// These tests pin the two properties that stops that coming back: the card
// has no text of its own beyond its heading, and it draws nothing at all
// when the engine stayed quiet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/insights/domain/suggestion_engine.dart';
import 'package:smartspoon/features/insights/presentation/widgets/recommendations.dart';

Future<void> _pump(WidgetTester tester, List<Suggestion> s) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Recommendations(suggestions: s, margin: EdgeInsets.zero),
        ),
      ),
    ));

const _one = Suggestion(
  id: 'satiation',
  kind: SuggestionKind.praise,
  title: 'You slowed down as you ate',
  body: 'Your bites came further apart as the meal went on.',
  evidence: 'acceleration -1.9 bites/min^2, R2 0.99 over 14 bites',
  priority: 80,
);

void main() {
  testWidgets('renders the engine title, body and evidence', (tester) async {
    await _pump(tester, const [_one]);
    expect(find.text(_one.title), findsOneWidget);
    expect(find.text(_one.body), findsOneWidget);
    // The evidence is on screen, not hidden behind a tap: a claim about
    // someone's eating is only worth reading if they can check it.
    expect(find.text(_one.evidence), findsOneWidget);
  });

  testWidgets('an empty engine result draws nothing', (tester) async {
    await _pump(tester, const []);
    // Not even the heading — a card with a title over no rows reads as a bug,
    // and "nothing to say" is a valid answer from the engine.
    expect(find.text('From your meals'), findsNothing);
    expect(find.byType(SuggestionRow), findsNothing);
  });

  testWidgets('every suggestion handed in gets a row', (tester) async {
    await _pump(tester, const [
      _one,
      Suggestion(
        id: 'pauses',
        kind: SuggestionKind.observation,
        title: 'You paused twice',
        body: 'Two breaks of over 30 s.',
        evidence: '2 pauses, longest 48 s',
        priority: 60,
      ),
    ]);
    expect(find.byType(SuggestionRow), findsNWidgets(2));
  });

  testWidgets('the retired fixed sentences are not reachable', (tester) async {
    await _pump(tester, const [_one]);
    expect(find.textContaining('Great progress'), findsNothing);
    expect(find.textContaining('try smaller bites'), findsNothing);
    expect(find.text('Personalized Suggestions'), findsNothing);
  });

  testWidgets('every kind has an icon, and only praise is tinted success',
      (tester) async {
    // Kind-keyed, so a new engine rule cannot reach the screen iconless.
    for (final kind in SuggestionKind.values) {
      expect(SuggestionRow.iconFor(kind), isNotNull);
    }
    final praise = SuggestionRow.colorFor(SuggestionKind.praise);
    for (final kind in SuggestionKind.values) {
      if (kind == SuggestionKind.praise) continue;
      expect(SuggestionRow.colorFor(kind), isNot(praise));
    }
  });
}
