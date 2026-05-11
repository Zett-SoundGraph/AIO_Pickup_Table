import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'arc_text_painter.dart';

// lib/components/guide_circle.dart

// class OrderGuideWidget extends StatelessWidget {
//   final String label;
//   final Color color;
//   final Map<String, ui.Image> icons;
//
//   const OrderGuideWidget({
//     super.key,
//     required this.label,
//     this.color = Colors.cyanAccent,
//     required this.icons,
//   });
//
//   @override
//   Widget build(BuildContext context) {
//     const double size = 180.0;
//     const double guideRadius = size / 2;
//     const double textRadius = guideRadius + 25.0; // 텍스트가 그려질 궤도
//     final double dynamicFontSize = label.length > 10 ? 12.0 : 15.0;
//     // 텍스트 스타일 설정 (컵과 동일한 스타일)
//     final TextStyle labelStyle = TextStyle(
//       color: Colors.white,
//       fontSize: dynamicFontSize,
//       fontWeight: FontWeight.bold,
//       letterSpacing: 1.5,
//       fontFamilyFallback: ['Noto Color Emoji'],
//     );
//
//     // 12시 방향 중앙 정렬을 위한 각도 계산
//     final textPainter = TextPainter(
//       text: TextSpan(text: label, style: labelStyle),
//       textDirection: TextDirection.ltr,
//     )..layout();
//
//     final double totalAngle = textPainter.width / textRadius;
//     // 12시 방향(-pi/2)을 기준으로 텍스트 너비의 절반만큼 뒤로 이동
//     final double startAngle12 = -math.pi / 2 + (totalAngle / 2);
//
//     return SizedBox(
//       width: size,
//       height: size,
//       child: Stack(
//         alignment: Alignment.center,
//         clipBehavior: Clip.none,
//         children: [
//           // 1. 가이드 이미지 (180도 회전 - 바리스타 시점)
//           Transform.rotate(
//             angle: math.pi,
//             child: Image.asset(
//               'assets/images/cafe_beta.png',
//               width: size,
//               height: size,
//               fit: BoxFit.contain,
//               // color: color.withOpacity(0.5), // 필요 시 색상 필터 적용 가능
//             ),
//           ),
//
//           // 2. 12시 방향 곡선 라벨
//           CustomPaint(
//             size: const Size(size, size),
//             painter: ArcTextPainter(
//               text: label,
//               radius: textRadius,
//               startAngle: startAngle12,
//               style: labelStyle,
//               icons: icons,
//             ),
//           ),
//
//           // 추후 여기에 Pulsing 애니메이션 등을 추가하기 매우 쉬워집니다.
//         ],
//       ),
//     );
//   }
// }
class OrderGuideWidget extends StatefulWidget {
  final String label;
  final Color color;
  final Map<String, ui.Image> icons;
  final int totalCups;

  const OrderGuideWidget({
    super.key,
    required this.label,
    this.color = Colors.cyanAccent,
    required this.icons,
    this.totalCups = 1,
  });

  @override
  State<OrderGuideWidget> createState() => _OrderGuideWidgetState();
}

class _OrderGuideWidgetState extends State<OrderGuideWidget> with SingleTickerProviderStateMixin {
  late AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    // 깜빡임 애니메이션 컨트롤러 (0.8초 주기로 밝아졌다 어두워졌다 반복)
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = 180.0 + ((widget.totalCups - 1) * 60.0);
    final double dynamicStroke = 5.0 + ((widget.totalCups - 1) * 2.5);
    // const double size = 180.0;
    final double guideRadius = size / 2;
    final double textRadius = guideRadius + 25.0; // 텍스트가 그려질 궤도
    final double dynamicFontSize = widget.label.length > 10 ? 12.0 : 15.0;

    // 텍스트 스타일 설정 (컵과 동일한 스타일)
    final TextStyle labelStyle = TextStyle(
      color: Colors.white,
      fontSize: dynamicFontSize,
      fontWeight: FontWeight.bold,
      letterSpacing: 1.5,
      fontFamilyFallback: const ['Noto Color Emoji'],
    );

    // 12시 방향 중앙 정렬을 위한 각도 계산
    final textPainter = TextPainter(
      text: TextSpan(text: widget.label, style: labelStyle),
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
          // 1. 깜빡이는 빨간색 점선 원 (기존 이미지 대체)
          AnimatedBuilder(
            animation: _blinkController,
            builder: (context, child) {
              final pulse = _blinkController.value;
              return Opacity(
                // 0.3 ~ 1.0 사이로 투명도가 변동하며 깜빡임 효과
                opacity: 0.5 + (pulse * 0.5),
                child: Transform.scale(
                  scale: 0.98 + (pulse * 0.05),
                  child: CustomPaint(
                    size: Size(size, size),
                    painter: DashedCirclePainter(
                      color: Colors.redAccent, // 빨간색 설정
                      strokeWidth: dynamicStroke,        // 점선의 두께
                      glowIntensity: pulse,
                    ),
                  ),
                ),
              );
            },
          ),

          // 2. 12시 방향 곡선 라벨
          CustomPaint(
            size: Size(size, size),
            painter: ArcTextPainter(
              text: widget.label,
              radius: textRadius,
              startAngle: startAngle12,
              style: labelStyle,
              icons: widget.icons,
            ),
          ),
        ],
      ),
    );
  }
}

// 점선 원을 그려주는 CustomPainter
// class DashedCirclePainter extends CustomPainter {
//   final Color color;
//   final double strokeWidth;
//   final double dashWidth;
//   final double dashSpace;
//   final double glowIntensity;
//
//   DashedCirclePainter({
//     required this.color,
//     this.strokeWidth = 3.0,
//     this.dashWidth = 15.0, // 점선 하나의 길이
//     this.dashSpace = 10.0, // 점선 사이의 간격
//     this.glowIntensity = 0.0,
//   });
//
//   @override
//   void paint(Canvas canvas, Size size) {
//     final paint = Paint()
//       ..color = color
//       ..strokeWidth = strokeWidth
//       ..style = PaintingStyle.stroke
//       ..strokeCap = StrokeCap.round; // 끝을 둥글게 처리하여 부드러운 느낌 제공
//
//     final center = Offset(size.width / 2, size.height / 2);
//     final radius = size.width / 2;
//     final perimeter = 2 * math.pi * radius; // 원의 둘레
//
//     int dashCount = (perimeter / (dashWidth + dashSpace)).floor();
//     double sweepAngle = (dashWidth / perimeter) * 2 * math.pi; // 선이 그려질 각도
//     double spaceAngle = (dashSpace / perimeter) * 2 * math.pi; // 비워둘 각도
//
//     double currentAngle = 0;
//     for (int i = 0; i < dashCount; i++) {
//       canvas.drawArc(
//         Rect.fromCircle(center: center, radius: radius),
//         currentAngle,
//         sweepAngle,
//         false,
//         paint,
//       );
//       currentAngle += sweepAngle + spaceAngle;
//     }
//   }
//
//   @override
//   bool shouldRepaint(DashedCirclePainter oldDelegate) {
//     return oldDelegate.color != color ||
//         oldDelegate.strokeWidth != strokeWidth;
//   }
// }
class DashedCirclePainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double dashWidth;
  final double dashSpace;
  final double glowIntensity; // 🌟 추가됨

  DashedCirclePainter({
    required this.color,
    this.strokeWidth = 3.0,
    this.dashWidth = 15.0,
    this.dashSpace = 10.0,
    this.glowIntensity = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 🌟 1. 빛 번짐(Neon Glow)을 위한 베이스 페인트
    final glowPaint = Paint()
      ..color = color.withOpacity(0.3 + (glowIntensity * 0.7)) // 밝기 조절
      ..strokeWidth = strokeWidth * 2.5 // 원본보다 두껍게 퍼지게
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12.0); // 네온사인 효과의 핵심!

    // 🌟 2. 선명한 중심선을 그리기 위한 메인 페인트
    final mainPaint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final perimeter = 2 * math.pi * radius;

    int dashCount = (perimeter / (dashWidth + dashSpace)).floor();
    double sweepAngle = (dashWidth / perimeter) * 2 * math.pi;
    double spaceAngle = (dashSpace / perimeter) * 2 * math.pi;

    double currentAngle = 0;
    final rect = Rect.fromCircle(center: center, radius: radius);

    for (int i = 0; i < dashCount; i++) {
      // 바닥에 글로우(빛 번짐)를 먼저 그리고
      canvas.drawArc(rect, currentAngle, sweepAngle, false, glowPaint);
      // 그 위에 선명한 선을 덮어 그립니다
      canvas.drawArc(rect, currentAngle, sweepAngle, false, mainPaint);

      currentAngle += sweepAngle + spaceAngle;
    }
  }

  @override
  bool shouldRepaint(DashedCirclePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.glowIntensity != glowIntensity;
  }
}