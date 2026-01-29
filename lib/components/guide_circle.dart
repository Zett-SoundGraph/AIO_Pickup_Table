import 'dart:ui';
import 'package:flutter/material.dart';

// lib/components/guide_circle.dart

class GuideCircle extends CustomPainter {
  final Color color;
  final double strokeWidth;

  GuideCircle({
    // 1. 색상을 조금 더 밝은 사이언 또는 화이트로 변경
    this.color = Colors.cyanAccent,
    this.strokeWidth = 2.5, // 두께를 살짝 키움
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 2. 빛 번짐 효과를 위한 그림자 Paint
    final shadowPaint = Paint()
      ..color = color.withOpacity(0.3)
      ..strokeWidth = strokeWidth + 2
      ..style = PaintingStyle.stroke;

    // 메인 선 Paint
    final paint = Paint()
      ..color = color.withOpacity(0.6) // 투명도를 0.6 정도로 상향
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final Path path = Path()..addOval(Rect.fromLTWH(0, 0, size.width, size.height));

    for (PathMetric pathMetric in path.computeMetrics()) {
      double distance = 0.0;
      const double dashWidth = 12.0; // 점선 길이를 조금 더 길게
      const double dashSpace = 8.0;

      while (distance < pathMetric.length) {
        final extractPath = pathMetric.extractPath(distance, distance + dashWidth);

        // 그림자(빛번짐) 먼저 그리기
        canvas.drawPath(extractPath, shadowPaint);
        // 메인 점선 그리기
        canvas.drawPath(extractPath, paint);

        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}