import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ArcTextPainter extends CustomPainter {
  final String text;
  final double radius;
  final double startAngle;
  final TextStyle style;
  final Map<String, ui.Image> icons;

  ArcTextPainter({
    required this.text,
    required this.radius,
    required this.startAngle,
    required this.style,
    required this.icons,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    double currentAngle = startAngle;

    for (var char in text.characters) {
      ui.Image? icon = icons[char]; // 현재 글자가 아이콘인지 확인

      if (icon != null) {
        // [이미지를 그리는 경우]
        const double iconSize = 24.0; // ✨ 화면에 표시될 아이콘 크기 (조절 가능)
        final charAngle = iconSize / radius;
        final x = center.dx + radius * math.cos(currentAngle - charAngle / 2);
        final y = center.dy + radius * math.sin(currentAngle - charAngle / 2);

        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(currentAngle - charAngle / 2 - math.pi / 2);

        // 128x128 원본을 iconSize(24x24)로 축소해서 그리기
        canvas.drawImageRect(
          icon,
          Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
          Rect.fromLTWH(-iconSize / 2, -iconSize / 2, iconSize, iconSize),
          Paint()..filterQuality = ui.FilterQuality.high,
        );
        canvas.restore();
        currentAngle -= charAngle;
      } else {
        // [글자를 그리는 경우 - 기존 로직]
        TextStyle finalStyle = (char == '|')
            ? style.copyWith(color: Colors.white38)
            : style;

        final textPainter = TextPainter(
          text: TextSpan(text: char, style: finalStyle),
          textDirection: TextDirection.ltr,
        )..layout();

        final charAngle = textPainter.width / radius;
        final x = center.dx + radius * math.cos(currentAngle - charAngle / 2);
        final y = center.dy + radius * math.sin(currentAngle - charAngle / 2);

        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(currentAngle - charAngle / 2 - math.pi / 2);
        textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
        canvas.restore();
        currentAngle -= charAngle;
      }
    }
  }

  @override
  bool shouldRepaint(ArcTextPainter oldDelegate) =>
      oldDelegate.text != text || oldDelegate.icons != icons;
}