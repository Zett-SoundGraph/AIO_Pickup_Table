import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../config/app_constants.dart';

class CoordinateTransformer {
  // [굴절/투영 상수] ToF 센서의 초점 거리 (수직 Z 계산을 위한 상수)
  static const double opticalCenterX = 320.0;
  static const double opticalCenterY = 240.0;
  static const double _fx = 620.0;
  static const double _fy = 620.0;

  // [9점 캘리브레이션 행렬] 초기값: 단순 3배 스케일링
  static List<double> _h = [3.0, 0.0, 0.0, 0.0, 2.25, 0.0, 0.0, 0.0, 1.0];

  // 모드 플래그
  static bool isCalibrationMode = false;

  static void resetMatrix() {
    _h = [3.0, 0.0, 0.0, 0.0, 2.25, 0.0, 0.0, 0.0, 1.0];
  }

  static void setHomographyMatrix(List<double> matrix) {
    _h = matrix;
    debugPrint("🚨 [MATRIX_UPDATED] Homography Matrix Applied.");
  }

  /// [핵심 1: 시차 보정 (Parallax Correction)]
  /// 직선 거리를 수직 거리로 변환하고 바닥면(Floor)으로 투영합니다.
  static Offset getFloorProjectedOffset(double rawX, double rawY, double zRaw) {
    // 1. 중심 기준 상대 좌표
    double dx = rawX - opticalCenterX;
    double dy = rawY - opticalCenterY;

    // 2. 수직 거리(Z-Depth) 계산 (굴절 상수 이용)
    double projectionFactor = math.sqrt(1 + math.pow(dx / _fx, 2) + math.pow(dy / _fy, 2));
    double zVert = zRaw / projectionFactor;

    // 3. 시차 보정 비율 계산 (천장높이 / 수직거리)
    double H = AppConstants.totalSensorHeight;
    double ratio = zVert / H;

    // 4. 바닥면 투영 좌표 반환
    return Offset(
      opticalCenterX + (dx * ratio),
      opticalCenterY + (dy * ratio),
    );
  }

  /// [핵심 2: 9점 캘리브레이션 변환 (Homography)]
  /// 보정된 바닥 좌표를 최종 UI 디스플레이 좌표로 변환합니다.
  static Offset transform(double rawX, double rawY, double zValue) {
    // 1단계: 시차 보정 적용
    Offset floorPos = getFloorProjectedOffset(rawX, rawY, zValue);

    double x = floorPos.dx;
    double y = floorPos.dy;

    // 2단계: 호모그래피 투영 변환 연산
    double denominator = _h[6] * x + _h[7] * y + _h[8];
    if (denominator == 0) denominator = 1.0;

    double ux = (_h[0] * x + _h[1] * y + _h[2]) / denominator;
    double uy = (_h[3] * x + _h[4] * y + _h[5]) / denominator;

    return Offset(ux, uy);
  }

  /// [핵심 3: 수직 거리 보정 (Corrected Z)]
  /// 렌즈 왜곡이 제거된 순수 수직 거리를 반환합니다.
  static double getCorrectedZ(double rawX, double rawY, double zRaw) {
    double dx = rawX - opticalCenterX;
    double dy = rawY - opticalCenterY;
    double projectionFactor = math.sqrt(1 + math.pow(dx / _fx, 2) + math.pow(dy / _fy, 2));
    return zRaw / projectionFactor;
  }

  // UI 크기 변환 헬퍼
  static Size getUiSize(double rawWidth, double rawHeight) => Size(rawWidth * 3.0, rawHeight * 3.0);
  static double getUiDiameter(double rawDiameter) => rawDiameter * 3.0;

  static void logTrace(String label, double rawX, double rawY, double zValue) {
    Offset floor = getFloorProjectedOffset(rawX, rawY, zValue);
    Offset finalPos = transform(rawX, rawY, zValue);

    debugPrint("""
[TRACE] 🔍 [$label]
   - Raw Input : (${rawX.toInt()}, ${rawY.toInt()}) Z: ${zValue.toInt()}
   - Floor Proj: (${floor.dx.toInt()}, ${floor.dy.toInt()}) [Parallax Applied]
   - UI Final  : (${finalPos.dx.toInt()}, ${finalPos.dy.toInt()}) [Homography Applied]
    """);
  }
}