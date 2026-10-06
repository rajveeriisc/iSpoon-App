// bite_timeline.dart — every bite of the meal on one line, coloured by how
// steady the hand was around it.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/engine/meal_tracker.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_card.dart';

class BiteTimeline extends StatelessWidget {
  const BiteTimeline({
    super.key,
    required this.bites,
    required this.start,
    required this.end,
  });

  final List<BiteEvent> bites;
  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final span = end.isAfter(start) ? end.difference(start) : Duration.zero;
    final spanMs = span.inMilliseconds < 60000 ? 60000 : span.inMilliseconds;
    return AiLabCard(
      title: 'Bite timeline',
      icon: Icons.timeline_rounded,
      child: Column(children: [
        SizedBox(
          height: 36,
          width: double.infinity,
          child: CustomPaint(
            painter: _TimelinePainter(
              positions: [
                for (final b in bites)
                  b.time.difference(start).inMilliseconds / spanMs,
              ],
              colors: [for (final b in bites) biteColor(b.rhythmicShare)],
              axis: theme.colorScheme.onSurface.withValues(alpha: 0.15),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('0:00', style: _small(context)),
            Text(mmss(Duration(milliseconds: spanMs)), style: _small(context)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _Legend(color: kSteadyGreen, label: 'Steady'),
          _Legend(color: kShakeAmber, label: 'Some shaking'),
          _Legend(color: kShakeRed, label: 'Shaky'),
        ]),
      ]),
    );
  }

  TextStyle? _small(BuildContext context) => Theme.of(context)
      .textTheme
      .bodySmall
      ?.copyWith(fontSize: 11, color: mutedText(context));
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontSize: 11, color: mutedText(context))),
      ]);
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({required this.positions, required this.colors, required this.axis});

  final List<double> positions;
  final List<Color> colors;
  final Color axis;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 8.0;
    final y = size.height / 2;
    final w = size.width - pad * 2;
    canvas.drawLine(
      Offset(pad, y),
      Offset(size.width - pad, y),
      Paint()
        ..color = axis
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < positions.length; i++) {
      final x = pad + positions[i].clamp(0.0, 1.0) * w;
      canvas.drawCircle(Offset(x, y), 6.5, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(x, y), 5, Paint()..color = colors[i]);
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.positions.length != positions.length ||
      old.axis != axis ||
      (positions.isNotEmpty && old.positions.last != positions.last);
}
