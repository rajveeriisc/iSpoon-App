// model_data_section.dart — hand setting, what the model is, the labelled
// meal recorder and the raw sensor view. Collapsed by default: this is the
// "under the hood" part of the page.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/handedness.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_view_data.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

class ModelDataSection extends StatelessWidget {
  const ModelDataSection({super.key, required this.data, required this.actions});

  final AiLabViewData data;
  final AiLabActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AiLabCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 18),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          leading: Icon(Icons.tune_rounded, color: theme.colorScheme.primary),
          title: Text('Settings & how it works',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          subtitle: Text('Which hand you use, how tracking works, sharing a meal',
              style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context))),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HandSetting(data: data, actions: actions),
            const SizedBox(height: 18),
            _ModelFacts(data: data),
            const SizedBox(height: 18),
            _Recorder(data: data, actions: actions),
            const SizedBox(height: 18),
            _RawSensor(actions: actions),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w800)),
      );
}

class _HandSetting extends StatelessWidget {
  const _HandSetting({required this.data, required this.actions});

  final AiLabViewData data;
  final AiLabActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detected = data.detectedHand;
    final note = data.handPreference != HandPreference.auto
        ? 'Using your setting.'
        : detected == null
            ? 'Detecting from your first bites…'
            : 'Detected: ${detected == Hand.right ? 'right' : 'left'} hand.';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading('Eating hand'),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<HandPreference>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: HandPreference.auto, label: Text('Auto')),
            ButtonSegment(value: HandPreference.right, label: Text('Right')),
            ButtonSegment(value: HandPreference.left, label: Text('Left')),
          ],
          selected: {data.handPreference},
          onSelectionChanged: (s) => actions.setHandPreference(s.first),
        ),
      ),
      const SizedBox(height: 6),
      Text(note, style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context))),
    ]);
  }
}

class _ModelFacts extends StatelessWidget {
  const _ModelFacts({required this.data});

  final AiLabViewData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = data.model;
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: mutedText(context), height: 1.4);
    if (m == null) return const SizedBox.shrink();
    final shake = m.steadiness.syntheticDetection['5Hz_20dps'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading('How it works'),
      Text(
        'Counting bites: your spoon watches itself tilt up to your mouth and '
        'back down. It learned that movement from ${m.bites} bites recorded by '
        '${m.people} people. Checked against people it had never seen before, '
        'it caught ${(m.evaluation.recall * 100).round()}% of real bites, and '
        '${(m.evaluation.precision * 100).round()}% of what it counted was '
        'genuinely a bite.',
        style: style,
      ),
      const SizedBox(height: 6),
      Text(
        'Steadiness: it listens for a regular shake while you eat, between 4 '
        'and 12 times a second. People without a tremor usually read '
        '${m.steadiness.normalSteadyPctMin.round()}% steady or better'
        '${shake == null ? '' : ', and in testing it picked up an added shake ${(shake * 100).round()}% of the time'}. '
        'It has not been tried with people who have a tremor yet, so treat it '
        'as something to follow over time rather than a verdict.',
        style: style,
      ),
      const SizedBox(height: 6),
      Text(
          'Version ${m.version}, built ${m.trainedOn}. All of this runs on your '
          'phone — nothing about your meals is sent anywhere to work it out.',
          style: style),
    ]);
  }
}

class _Recorder extends StatelessWidget {
  const _Recorder({required this.data, required this.actions});

  final AiLabViewData data;
  final AiLabActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = data.recorder;
    final muted = theme.textTheme.bodySmall?.copyWith(color: mutedText(context));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading('Help improve iSpoon'),
      if (!r.recording) ...[
        Text(
          'Record a meal and tap Bite each time the spoon reaches your mouth. '
          'That gives us a meal we know the answer to, which is how the '
          'counting gets better. It stays on your phone until you send it.',
          style: muted,
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: data.streaming ? actions.startRecording : null,
            icon: const Icon(Icons.fiber_manual_record, size: 16),
            label: const Text('Record a meal'),
          ),
          if (r.lastSavedPath != null)
            TextButton.icon(
              onPressed: () => Share.shareXFiles([XFile(r.lastSavedPath!)],
                  text: 'SmartSpoon labelled meal'),
              icon: const Icon(Icons.ios_share, size: 16),
              label: const Text('Send last recording'),
            ),
        ]),
        const SizedBox(height: 4),
        Text(
            r.savedCount == 1
                ? '1 recording saved on this phone.'
                : '${r.savedCount} recordings saved on this phone.',
            style: muted),
      ] else ...[
        Text(
            'Recording · ${r.seconds.round()}s · ${r.marks} '
            '${r.marks == 1 ? 'bite' : 'bites'} marked',
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed: () {
              HapticFeedback.mediumImpact();
              actions.markBite();
            },
            icon: const BowlSpoonIcon(size: 24),
            label: const Text('Bite', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          TextButton(onPressed: r.marks > 0 ? actions.undoMark : null, child: const Text('Undo last')),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              final path = await actions.saveRecording();
              messenger?.showSnackBar(SnackBar(
                  content: Text(path == null ? 'Nothing was recorded.' : 'Recording saved.')));
            },
            child: const Text('Save'),
          ),
          TextButton(onPressed: actions.cancelRecording, child: const Text('Discard')),
        ]),
      ],
    ]);
  }
}

class _RawSensor extends StatelessWidget {
  const _RawSensor({required this.actions});

  final AiLabActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading('Spoon movement'),
      SizedBox(
        height: 70,
        child: ValueListenableBuilder<List<double>>(
          valueListenable: actions.liveGyro,
          builder: (context, v, _) => v.length < 2
              ? Center(
                  child: Text('Nothing from the spoon yet.',
                      style: theme.textTheme.bodySmall?.copyWith(color: mutedText(context))))
              : LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    minY: 0,
                    maxY: 300,
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < v.length; i++)
                            FlSpot(i.toDouble(), v[i].clamp(0.0, 300.0)),
                        ],
                        color: theme.colorScheme.primary,
                        barWidth: 1.5,
                        dotData: const FlDotData(show: false),
                      ),
                    ],
                  ),
                  duration: Duration.zero,
                ),
        ),
      ),
      Text('How fast the spoon is turning, over the last 2 seconds',
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: mutedText(context))),
    ]);
  }
}
