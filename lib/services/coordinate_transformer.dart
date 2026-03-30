import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../config/app_constants.dart';

class CoordinateTransformer {
  static double _lerp(double a, double b, double t) {
    return a + (b - a) * t;
  }
  // 🌟 [변경] 기존 _h(9개) 대신 대표님 방식의 12개 계수 저장 (ax1~6, ay1~6)
  static List<double> _coeffs = List.filled(12, 0.0);
  static List<Offset> _residuals = List.generate(9, (_) => Offset.zero);

  //static const double fixedCupHeight = 110.0;
  static const double opticalCenterX = 320.0;
  static const double opticalCenterY = 240.0;

  static const double _fx = 290.0;
  static const double _fy = 320.0;

  //static double uiPostGain = 1.0;

  static void updateResiduals(List<Offset> newResiduals) {
    _residuals = newResiduals;
  }

  // 🌟 [변경] 행렬 세터 대신 다항식 계수 세터로 교체
  static void setPolynomialCoefficients(List<double> coeffs) {
    _coeffs = coeffs;
    debugPrint("🎯 [Transformer] 2차 다항식 계수(12개) 적용 완료");
  }

  static void resetMatrix() {
    _coeffs = List.filled(12, 0.0);
    _residuals = List.generate(9, (_) => Offset.zero);
  }

  static Offset getFixedParallax(double rawX, double rawY, double zRaw) {
    // 1. 좌표계를 광원(테이블 센터) 기준으로 변환 (Shift to Origin)
    double dx = rawX - opticalCenterX;
    double dy = rawY - opticalCenterY;

    double projectionFactor = math.sqrt(1 + math.pow(dx / _fx, 2) + math.pow(dy / _fy, 2));

    // 이것이 렌즈에서 물체 윗면까지의 실제 "수직 거리"입니다.
    double zVert = zRaw / projectionFactor;
    //debugPrint("🔍 [Z-DEBUG] RawZ: ${zRaw.toStringAsFixed(1)} -> VertZ: ${zVert.toStringAsFixed(1)} (Factor: ${projectionFactor.toStringAsFixed(3)})");
    // 2. 비례식 계산 (H: 센서높이, h: 컵높이)
    double H = AppConstants.totalSensorHeight;
    double ratio = (zVert / H).clamp(0.0, 1.0);

    return Offset(opticalCenterX + dx * ratio, opticalCenterY + dy * ratio);
  }

  static double getCorrectedZ(double rawX, double rawY, double zRaw) {
    double dx = rawX - opticalCenterX;
    double dy = rawY - opticalCenterY;
    double projectionFactor = math.sqrt(1 + math.pow(dx / _fx, 2) + math.pow(dy / _fy, 2));
    return zRaw / projectionFactor;
  }

  /// [2단계] 최종 변환 함수 (대표님 제안: 2차 다항식 엔진)
  static Offset transform(double rawX, double rawY, double zValue) {
    Offset g = getFixedParallax(rawX, rawY, zValue);

    // 🌟 입력 정규화 (솔버와 동일하게)
    double x = g.dx / 640.0;
    double y = g.dy / 480.0;

    if (_coeffs.every((c) => c == 0.0)) return Offset(g.dx * 3.0, g.dy * 2.25);

    // 2차 다항식 연산
    double nux = _coeffs[0] + _coeffs[1] * x + _coeffs[2] * y +
        _coeffs[3] * x * y + _coeffs[4] * x * x + _coeffs[5] * y * y;
    double nuy = _coeffs[6] + _coeffs[7] * x + _coeffs[8] * y +
        _coeffs[9] * x * y + _coeffs[10] * x * x + _coeffs[11] * y * y;

    // 🌟 결과 복원 (0~1 범위를 다시 픽셀로)
    double ux = nux * 1920.0;
    double uy= nuy * 1080.0;

    Offset interpolation = _calculateInterpolatedOffset(ux, uy);

    return Offset(ux + interpolation.dx, uy + interpolation.dy);
  }

  static bool isCalibrationMode = false;

  static Offset applyVisualPull(Offset mathOffset, double zValue) {
    if (isCalibrationMode) {
      return mathOffset;
    }
    // 1. 중심으로부터의 거리 계산
    // double dx = mathOffset.dx - 960;
    // double dy = mathOffset.dy - 540;
    // double dist = math.sqrt(dx * dx + dy * dy);
    const Offset center = Offset(960, 540);

    double vx = mathOffset.dx - center.dx;
    double vy = mathOffset.dy - center.dy;
    double d = math.sqrt(vx * vx + vy * vy);

    if (d < 1.0) return mathOffset;

    const double leftWeight = 1.75;
    const double rightWeight = 1.35;
    const double topWeight = 0.95;
    const double bottomWeight = 0.65;

    double tx = (vx / d).clamp(-1.0, 1.0);
    double ty = (vy / d).clamp(-1.0, 1.0);

    double horizontalW = (tx < 0) ? _lerp(1.0, leftWeight, tx.abs()) : _lerp(1.0, rightWeight, tx.abs());
    double verticalW = (ty < 0) ? _lerp(1.0, topWeight, ty.abs()) : _lerp(1.0, bottomWeight, ty.abs());
    double finalW = (horizontalW + verticalW) / 2.0;

    const double refCupHeight = 110.0;
    double currentCupHeight = (AppConstants.totalSensorHeight - zValue).clamp(50.0, 250.0);
    double heightWeight = currentCupHeight / refCupHeight;

    // 3. 이차함수 기반 Pull량(Pixel) 계산
    // PullAmount = (a * d^2 + b * d) * heightWeight
    // 초기 계수 (현장 테스트 후 미세조정 필요)
    const double a = 0.00000012;
    const double b = 0.16;

    double pullPixel = (a * math.pow(d, 3) + b * d) * heightWeight * finalW;

    // 4. 방향 벡터 정규화 (Unit Vector)
    double unitX = vx / d;
    double unitY = vy / d;

    // 5. 최종 좌표: 수학적 좌표에서 중심 방향으로 pullPixel만큼 이동
    double finalX = mathOffset.dx - (unitX * pullPixel);
    double finalY = mathOffset.dy - (unitY * pullPixel);

    return Offset(finalX, finalY);

    // const double referenceZ = 980.0;
    // const double sensorHeight = 1090.0; // 실제 설치 높이 (AppConstants.totalSensorHeight)

    // // 현재 컵의 높이 비율 vs 기준 컵의 높이 비율
    // double currentRatio = (zValue / sensorHeight).clamp(0.5, 1.0);
    // double referenceRatio = (referenceZ / sensorHeight);
    //
    // double adaptiveBaseGain = 0.65 * (currentRatio / referenceRatio);
    // // 2. 다이내믹 게인 계산
    // // 중심(dist=0)에 가까울수록 uiPostGain(0.88)에 가깝고,
    // // 멀어질수록(dist가 커질수록) Gain이 1.0에 가까워지도록(덜 당기도록) 설계합니다.
    // // 1100은 화면 대각선 끝까지의 대략적인 거리입니다.
    // double releaseFactor = 0.25;
    // double dynamicGain = adaptiveBaseGain + (dist / 1050) * releaseFactor;
    //
    // // Gain이 1.0을 넘지 않도록 제한
    // dynamicGain = dynamicGain.clamp(0.0, 1.0);
    //
    // double finalX = 960 + dx * dynamicGain;
    // double finalY = 540 + dy * dynamicGain;
    //
    // // 디버깅을 위해 로그에 dynamicGain을 찍어줍니다.
    // debugPrint("[TRACE] Dynamic Gain applied: ${dynamicGain.toStringAsFixed(3)} at dist: ${dist.toInt()}");
    //
    // return Offset(finalX, finalY);
  }

  /// IDW(Inverse Distance Weighting) 보간 로직 (기존과 동일)
  static Offset _calculateInterpolatedOffset(double x, double y) {
    final List<Offset> targets = [
      const Offset(960, 540), const Offset(150, 150), const Offset(1770, 150),
      const Offset(1770, 930), const Offset(150, 930), const Offset(960, 150),
      const Offset(1770, 540), const Offset(960, 930), const Offset(150, 540),
    ];

    double totalWeight = 0;
    double resX = 0;
    double resY = 0;

    for (int i = 0; i < 9; i++) {
      double dist = (Offset(x, y) - targets[i]).distance;
      double weight = 1.0 / (math.pow(dist, 2.0) + 1.0);
      resX += _residuals[i].dx * weight;
      resY += _residuals[i].dy * weight;
      totalWeight += weight;
    }

    return totalWeight == 0 ? Offset.zero : Offset(resX / totalWeight, resY / totalWeight);
  }

  static Size getUiSize(double rawWidth, double rawHeight) => Size(rawWidth * 3.17, rawHeight * 3.17);
  static double getUiDiameter(double rawDiameter) => rawDiameter * 3.17;

  static void logTrace(String label, double rawX, double rawY, double zValue) {
    // 1단계: 시차 보정
    Offset parallax = getFixedParallax(rawX, rawY, zValue);

    // 2단계: 다항식 변환 (정규화 포함)
    double x = (parallax.dx) / 640.0;
    double y = (parallax.dy) / 480.0;
    double nux = _coeffs[0] + _coeffs[1] * x + _coeffs[2] * y + _coeffs[3] * x * y + _coeffs[4] * x * x + _coeffs[5] * y * y;
    double nuy = _coeffs[6] + _coeffs[7] * x + _coeffs[8] * y + _coeffs[9] * x * y + _coeffs[10] * x * x + _coeffs[11] * y * y;
    Offset poly = Offset(nux * 1920.0, nuy * 1080.0);

    // 3단계: 보간 적용 (IDW)
    Offset inter = _calculateInterpolatedOffset(poly.dx, poly.dy);
    Offset mathFinal = Offset(poly.dx + inter.dx, poly.dy + inter.dy);

    // 4단계: 시각적 당김 적용 (Gain)
    Offset visualFinal = applyVisualPull(mathFinal, zValue);

    double dx = mathFinal.dx - 960;
    double dy = mathFinal.dy - 540;
    double d = math.sqrt(dx * dx + dy * dy);

    debugPrint("""
[TRACE] 🔍 [LABEL: $label]
[TRACE]    - [TRACE 0] Raw Input: (${rawX.toInt()}, ${rawY.toInt()}) Z: ${zValue.toInt()}
[TRACE]    - [TRACE 1] Parallax : (${parallax.dx.toInt()}, ${parallax.dy.toInt()})
[TRACE]    - [TRACE 2] Poly Only: (${poly.dx.toInt()}, ${poly.dy.toInt()})
[TRACE]    - [TRACE 3] Math(IDW): (${mathFinal.dx.toInt()}, ${mathFinal.dy.toInt()}) [잔차: ${inter.dx.toInt()}, ${inter.dy.toInt()}]
[TRACE]    - [TRACE 4] Visual(Q): (${visualFinal.dx.toInt()}, ${visualFinal.dy.toInt()}) [Dist: ${d.toInt()}px]
  """);
  }
}