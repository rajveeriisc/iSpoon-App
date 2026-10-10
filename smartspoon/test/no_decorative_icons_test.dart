// The interface must not look generated.
//
// Reported twice: the small symbols "feels app ai genrted", then specifically
// the bulb and heart. The pattern behind both complaints is a decorative glyph
// that carries no information — a lightbulb for anything called an insight, a
// heart for anything asking goodwill, a brain for anything called AI — usually
// sitting in a tinted or gradient rounded square. Every generated-app template
// ships exactly these, which is why they read as one.
//
// Functional icons are fine and are not what this guards: a leading glyph that
// distinguishes list items, a chevron that means "opens", a check that means
// "done". The test bans the specific decorative set, by name, so it cannot
// quietly return in a later redesign.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartspoon/features/home/presentation/widgets/home_cards.dart';

/// Banned glyphs, with why each one was removed.
const _banned = <String, String>{
  'Icons.lightbulb_outline': 'the stock "insight" bulb, was on the home tip card',
  'Icons.lightbulb': 'same bulb, filled',
  'Icons.tips_and_updates': 'bulb with sparkles — the stock "AI suggestion" glyph',
  'Icons.psychology_alt': 'a brain on a gradient tile; overstates a bite counter',
  'Icons.psychology': 'as above',
  'Icons.auto_awesome': 'sparkles, the "magic AI" glyph',
  'Icons.emoji_objects': 'another bulb',
  // Cutlery: a knife and fork is wrong for a spoon product, and one of the
  // places it appeared labels the moment the spoon is IN the food. All 17
  // sites now use the painted BowlSpoonIcon instead.
  'Icons.restaurant': 'knife and fork',
  'Icons.local_dining': 'knife and fork',
  'Icons.dinner_dining': 'a fork in pasta',
  'Icons.lunch_dining': 'a sandwich',
};

/// The painted glyph's own file names the icons it replaced, in prose.
const _iconSourceFile = 'lib/core/widgets/bowl_spoon_icon.dart';

/// Heart glyphs are banned as decoration but legitimate as a data icon, so
/// these are checked against an explicit allowlist of places that may use one.
const _heartGlyphs = <String>[
  'Icons.favorite',
  'Icons.favorite_border',
  'Icons.favorite_rounded',
];

/// Files allowed to use a heart, and the reason.
const _heartAllowed = <String, String>{
  // A notification whose type IS "health" renders a heart as its category
  // icon. That is a data-driven glyph, not decoration.
  'lib/features/notifications/presentation/screens/notification_screen.dart':
      'per-notification category icon',
};

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('no decorative bulb, sparkle or brain glyph anywhere in lib/', () {
    final offences = <String>[];
    for (final file in _dartFiles()) {
      if (file.path == _iconSourceFile) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Skip the prose explaining why these are banned.
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
        for (final entry in _banned.entries) {
          if (line.contains(entry.key)) {
            offences.add('${file.path}:${i + 1} ${entry.key} — ${entry.value}');
          }
        }
      }
    }
    expect(offences, isEmpty,
        reason: 'decorative glyphs are back:\n${offences.join('\n')}');
  });

  test('hearts only where a heart is the data, not the decoration', () {
    final offences = <String>[];
    for (final file in _dartFiles()) {
      if (_heartAllowed.containsKey(file.path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
        for (final glyph in _heartGlyphs) {
          if (lines[i].contains(glyph)) {
            offences.add('${file.path}:${i + 1} $glyph');
          }
        }
      }
    }
    expect(offences, isEmpty,
        reason: 'decorative heart(s) added:\n${offences.join('\n')}\n'
            'If a heart is genuinely the data, add the file to _heartAllowed '
            'with the reason.');
  });

  testWidgets('the motivation card is the quote and nothing else',
      (tester) async {
    // The card sizes its type with .sp/.h, so ScreenUtil has to be
    // initialised or the widget throws LateInitializationError before it
    // paints anything. designSize matches main.dart.
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(393, 852),
        builder: (_, __) => const MaterialApp(
          home: Scaffold(body: MotivationCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Icon), findsNothing,
        reason: 'the heart chip is back on the motivation card');
    // The "Motivation" heading went too: a pull quote in italics inside
    // quotation marks does not need a label saying it is motivational.
    expect(find.text('Motivation'), findsNothing);
    // It must still actually show a quote.
    final text = tester.widget<Text>(find.byType(Text).first).data ?? '';
    expect(text.trim(), startsWith('"'), reason: 'quote missing');
  });
}
