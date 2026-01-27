import 'dart:math' as math;
import 'package:flutter/material.dart';

class ArcTextPainter extends CustomPainter {
  final String text;
  final double radius;
  final double startAngle;
  final TextStyle style;

  ArcTextPainter({
    required this.text,
    required this.radius,
    required this.startAngle,
    required this.style,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    double currentAngle = startAngle;

    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      final textPainter = TextPainter(
        text: TextSpan(text: char, style: style),
        textDirection: TextDirection.ltr,
      )..layout();

      final charAngle = textPainter.width / radius;

      // 수학적 좌표 계산: x = r * cos(θ), y = r * sin(θ)
      final x = center.dx + radius * math.cos(currentAngle - charAngle / 2);
      final y = center.dy + radius * math.sin(currentAngle - charAngle / 2);

      canvas.save();
      canvas.translate(x, y);

      // 원의 접선 방향에 맞춰 글자 회전
      canvas.rotate(currentAngle - charAngle / 2 - math.pi / 2);

      textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
      canvas.restore();

      currentAngle -= charAngle;
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}