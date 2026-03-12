import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'arc_text_painter.dart';

// lib/components/guide_circle.dart

class OrderGuideWidget extends StatelessWidget {
  final String label;
  final Color color;
  final Map<String, ui.Image> icons;

  const OrderGuideWidget({
    super.key,
    required this.label,
    this.color = Colors.cyanAccent,
    required this.icons,
  });

  @override
  Widget build(BuildContext context) {
    const double size = 180.0;
    const double guideRadius = size / 2;
    const double textRadius = guideRadius + 25.0; // 텍스트가 그려질 궤도
    final double dynamicFontSize = label.length > 10 ? 12.0 : 15.0;
    // 텍스트 스타일 설정 (컵과 동일한 스타일)
    final TextStyle labelStyle = TextStyle(
      color: Colors.white,
      fontSize: dynamicFontSize,
      fontWeight: FontWeight.bold,
      letterSpacing: 1.5,
      fontFamilyFallback: ['Noto Color Emoji'],
    );

    // 12시 방향 중앙 정렬을 위한 각도 계산
    final textPainter = TextPainter(
      text: TextSpan(text: label, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final double totalAngle = textPainter.width / textRadius;
    // 12시 방향(-pi/2)을 기준으로 텍스트 너비의 절반만큼 뒤로 이동
    final double startAngle12 = -math.pi / 2 + (totalAngle / 2);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // 1. 가이드 이미지 (180도 회전 - 바리스타 시점)
          Transform.rotate(
            angle: math.pi,
            child: Image.asset(
              'assets/images/cafe_beta.png',
              width: size,
              height: size,
              fit: BoxFit.contain,
              // color: color.withOpacity(0.5), // 필요 시 색상 필터 적용 가능
            ),
          ),

          // 2. 12시 방향 곡선 라벨
          CustomPaint(
            size: const Size(size, size),
            painter: ArcTextPainter(
              text: label,
              radius: textRadius,
              startAngle: startAngle12,
              style: labelStyle,
              icons: icons,
            ),
          ),

          // 추후 여기에 Pulsing 애니메이션 등을 추가하기 매우 쉬워집니다.
        ],
      ),
    );
  }
}