import 'dart:ui';

import 'package:flutter/material.dart';

class HandDetectionOverlay extends StatefulWidget {
  final bool visible;
  const HandDetectionOverlay({super.key, required this.visible});

  @override
  State<HandDetectionOverlay> createState() => _HandDetectionOverlayState();
}

class _HandDetectionOverlayState extends State<HandDetectionOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true); // 0.5초 간격으로 깜빡임
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _controller.value, // 애니메이션에 따른 투명도 변화
          child: CustomPaint(
            size: Size.infinite,
            painter: DashedBorderPainter(),
          ),
        );
      },
    );
  }
}

class DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.orangeAccent // 경고 의미의 오렌지 또는 취향껏 변경
      ..strokeWidth = 8.0
      ..style = PaintingStyle.stroke;

    final Path path = Path();
    // 화면 가장자리에서 살짝 안쪽(4px)으로 경로 설정
    path.addRect(Rect.fromLTWH(4, 4, size.width - 8, size.height - 8));

    const double dashWidth = 20.0;
    const double dashSpace = 15.0;
    double distance = 0.0;

    // 점선 그리기 로직
    for (PathMetric measurePath in path.computeMetrics()) {
      while (distance < measurePath.length) {
        canvas.drawPath(
          measurePath.extractPath(distance, distance + dashWidth),
          paint,
        );
        distance += dashWidth + dashSpace;
      }
      distance = 0;
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}