// bowl_spoon_icon.dart — a bowl with a spoon in it, drawn rather than borrowed.
//
// The two places this replaces both used Icons.restaurant_rounded, which is a
// knife and fork. That is wrong twice over: the product is a spoon, and the
// moment being labelled is "collecting food" — the spoon in the bowl. Material
// has no bowl-and-spoon glyph (rice_bowl and ramen_dining are a bare bowl and
// a bowl with chopsticks), so this is painted.
//
// Drawn on the same 24x24 grid and with the same stroke weight as the rounded
// outlined Material set used everywhere else, so it sits in a row of real
// icons without looking pasted in.
import 'dart:math' as math;

import 'package:flutter/material.dart';

class BowlSpoonIcon extends StatelessWidget {
  const BowlSpoonIcon({super.key, this.size, this.color});

  /// Both default to IconTheme, so this can be dropped anywhere an Icon goes —
  /// including inside a widget that sizes and colours its glyph by wrapping it
  /// in an IconTheme — without the caller restating either.
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final resolved = color ?? theme.color ?? Colors.black;
    final dim = size ?? theme.size ?? 24.0;
    return SizedBox.square(
      dimension: dim,
      child: CustomPaint(
        // CustomPaint contributes no semantics of its own, which is right
        // here: every caller pairs this with a visible text label
        // ("Collecting food", "Bite"), so there is nothing for a screen
        // reader to announce separately.
        painter: _BowlSpoonPainter(resolved),
      ),
    );
  }
}

class _BowlSpoonPainter extends CustomPainter {
  _BowlSpoonPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Everything below is expressed on a 24x24 grid and scaled once, so the
    // proportions hold at any size.
    final k = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      // 1.8/24 matches the Material outlined weight at 24 px.
      ..strokeWidth = 1.8 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // ── bowl ────────────────────────────────────────────────────────────────
    // Lower half of an ellipse spanning x 3.5..20.5, with its rim at y 13.
    final bowl = Rect.fromLTRB(3.5 * k, 6.5 * k, 20.5 * k, 19.5 * k);
    canvas.drawArc(bowl, 0, math.pi, false, p);

    // The rim, drawn slightly inside the arc ends so the round caps meet the
    // curve instead of poking past it.
    canvas.drawLine(
      Offset(3.9 * k, 13 * k),
      Offset(20.1 * k, 13 * k),
      p,
    );

    // ── spoon ───────────────────────────────────────────────────────────────
    // Handle rising out of the bowl to the upper right. It starts below the
    // rim so the spoon reads as being IN the bowl rather than resting on it.
    canvas.drawLine(
      Offset(12.2 * k, 15.6 * k),
      Offset(17.4 * k, 7.6 * k),
      p,
    );

    // The spoon's own bowl: a small ellipse on the handle's axis. Rotating the
    // canvas about the ellipse centre is what keeps it aligned to the handle
    // instead of sitting at an angle to it.
    const cx = 18.4, cy = 6.0;
    // atan2 of the handle vector, so the two stay consistent if either moves.
    final angle = math.atan2(7.6 - 15.6, 17.4 - 12.2);
    canvas.save();
    canvas.translate(cx * k, cy * k);
    canvas.rotate(angle + math.pi / 2);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 4.4 * k, height: 3.2 * k),
      p,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BowlSpoonPainter old) => old.color != color;
}
