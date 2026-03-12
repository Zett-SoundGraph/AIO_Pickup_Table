import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

import '../config/app_constants.dart';

class CoordinateTransformer {
  // 1. 호모그래피 행렬 저장 변수 (초기값은 변환이 없는 '단위 행렬')
  static List<double> _h = [1, 0, 0, 0, 1, 0, 0, 0, 1];
  static List<Offset> _residuals = List.generate(9, (_) => Offset.zero);
  static const double focalLength = 360.0;
  static const double opticalCenterX = 320.0;
  static const double opticalCenterY = 240.0;
  static const double k1 = 0;
  static void updateResiduals(List<Offset> newResiduals) {
    _residuals = newResiduals;
  }
  // 2. 행렬 업데이트 함수 (Calibration 완료 후 호출됨)
  static void setHomographyMatrix(List<double> matrix) {
    _h = matrix;
    print("🎯 CoordinateTransformer: 새로운 호모그래피 행렬이 적용되었습니다.");
  }

  static void resetMatrix() {
    _h = [1, 0, 0, 0, 1, 0, 0, 0, 1];
    debugPrint("🔄 [Transformer] 행렬이 초기화되었습니다. (Collapse 현상 방지)");
  }

  static Offset getParallaxCorrectedOffset(double rawX, double rawY, double zRaw, {bool showLog = false, bool applyDistortion = true}) {
    // ---------------------------------------------------------
    // 1. 방사 왜곡 보정 (Radial Undistortion) - 사이 구간 밀림 해결
    // ---------------------------------------------------------
    // 중심으로부터의 거리를 정규화(Normalized)하여 왜곡률 계산
    double undistortedX = rawX;
    double undistortedY = rawY;

    if (applyDistortion) {
      double nx = (rawX - opticalCenterX) / focalLength;
      double ny = (rawY - opticalCenterY) / focalLength;
      double rSq = nx * nx + ny * ny;
      double distortionFactor = 1.0 + k1 * rSq;

      undistortedX = opticalCenterX + (rawX - opticalCenterX) * distortionFactor;
      undistortedY = opticalCenterY + (rawY - opticalCenterY) * distortionFactor;
    }

    // ---------------------------------------------------------
    // 2. 시차 보정 (currentFloor는 1000.0 고정)
    // ---------------------------------------------------------
    double dx = undistortedX - opticalCenterX;
    double dy = undistortedY - opticalCenterY;
    double r = math.sqrt(dx * dx + dy * dy);

    double theta = math.atan2(r, focalLength);
    double zVert = zRaw * math.cos(theta);
    double currentFloor = AppConstants.totalSensorHeight; // 실측 표준값 고정

    double correctionFactor = (currentFloor > 0) ? (zVert / currentFloor) : 1.0;

    return Offset(
      opticalCenterX + dx * correctionFactor,
      opticalCenterY + dy * correctionFactor,
    );
  }

  //static bool _isFirstHeightSet = false;
  // static void updateFloorHeight(double rawZ) {
  //   // 센서가 측정한 광학적 바닥 높이를 그대로 신뢰합니다.
  //   double currentHeight = AppConstants.totalSensorHeight;
  //   double diff = (rawZ - currentHeight).abs();
  //
  //   // 첫 실행이거나, 변화량이 5mm 이상일 때만 업데이트
  //   if (!_isFirstHeightSet || diff >= 5.0) {
  //     AppConstants.totalSensorHeight = rawZ - 120;
  //     _isFirstHeightSet = true;
  //
  //     debugPrint(
  //         "📢 [Sensor Sync] 바닥 높이(base_z) 확정: ${rawZ.toStringAsFixed(1)}mm");
  //     if (diff >= 5.0 && _isFirstHeightSet) {
  //       debugPrint("⚠️ 환경 변화 감지 (차이: ${diff.toStringAsFixed(1)}mm)");
  //     }
  //   }
  // }
  /// 1000으로 높이 고정
  static void updateFloorHeight(double rawZ) {
    // 실측값 고정 모드이므로 센서 데이터(rawZ)를 무시합니다.
    // 필요 시 로그만 남겨 실제 센서 측정값과 실측값의 차이만 모니터링합니다.
    if (AppConstants.isDebug) {
      double diff = (rawZ - AppConstants.totalSensorHeight).abs();
      if (diff > 10.0) {
        // debugPrint("ℹ️ [Sensor Sync] 고정값(1000) 대비 센서 실측치 차이: ${diff.toStringAsFixed(1)}mm");
      }
    }
  }

  static Offset transform(double rawX, double rawY, double zValue, {bool showLog = false}) {
    // 1. 센서 평면의 왜곡과 시차를 먼저 제거하여 '순수한 바닥 좌표'를 얻음
    Offset groundPoint = getParallaxCorrectedOffset(rawX, rawY, zValue, showLog: showLog);

    // 2. 호모그래피 변환
    double den = _h[6] * groundPoint.dx + _h[7] * groundPoint.dy + _h[8];
    if (den == 0) den = 1.0;
    double bx = (_h[0] * groundPoint.dx + _h[1] * groundPoint.dy + _h[2]) / den;
    double by = (_h[3] * groundPoint.dx + _h[4] * groundPoint.dy + _h[5]) / den;

    // double zDiff = (zValue - referenceZ) / referenceZ;
    // bx += (bx - 960) * zDiff * zSensitivity;
    // by += (by - 540) * zDiff * zSensitivity;

    // 3. 9포인트 잔차 보정 (Bilinear Interpolation)
    Offset residual = _applyBilinearCorrection(bx, by);
    double finalX = bx + residual.dx;
    double finalY = by + residual.dy;

    // [추가] 실시간 UI 좌표 로그 (컵 업데이트 시에만 출력)
    if (showLog && AppConstants.isDebug) {
      debugPrint("🎯 [UI_COORD] X: ${finalX.toStringAsFixed(1)}, Y: ${finalY.toStringAsFixed(1)}");
    }

    if (showLog && residual != Offset.zero) {
      debugPrint("🛠️ [Correction Applied] Raw_UI: ($bx, $by) -> Residual: (${residual.dx.toStringAsFixed(1)}, ${residual.dy.toStringAsFixed(1)})");
    }

    return Offset(finalX, finalY);
  }

  static Offset _applyBilinearCorrection(double x, double y) {
    // 9개 지점을 4개의 사각형 구역으로 나누어 보간 수행
    // x, y 좌표가 어느 사분면에 있는지 판단 (예: 좌상단, 우상단 등)
    // 여기서는 간략화를 위해 가장 가까운 4개 점의 가중치 평균 사용

    // 9개 지점의 UI 좌표 정의 (CalibrationScreen의 targetPoints와 동일해야 함)
    final List<Offset> targets = [
      const Offset(960, 540), const Offset(150, 150), const Offset(1770, 150),
      const Offset(1770, 930), const Offset(150, 930), const Offset(960, 150),
      const Offset(1770, 540), const Offset(960, 930), const Offset(150, 540),
    ];

    double totalWeight = 0;
    double resX = 0;
    double resY = 0;

    for (int i = 0; i < 9; i++) {
      double dist = math.sqrt(math.pow(x - targets[i].dx, 2) + math.pow(y - targets[i].dy, 2));
      // 거리에 반비례하는 가중치 (Inverse Distance Weighting)
      double weight = 1.0 / (math.pow(dist, 2.0) + 1.0);
      resX += _residuals[i].dx * weight;
      resY += _residuals[i].dy * weight;
      totalWeight += weight;
    }
    if (totalWeight == 0) return Offset.zero;
    return Offset(resX / totalWeight, resY / totalWeight);
  }

  static Size getUiSize(double rawWidth, double rawHeight) {
    double w = (rawWidth > 0) ? rawWidth : 80.0;
    double h = (rawHeight > 0) ? rawHeight : 80.0;

    // 크기 변환용 배율은 행렬의 평균 스케일을 추출해 쓸 수도 있으나,
    // 일관성을 위해 기존에 검증된 scaleX(3.17 등)를 상수로 유지하는 것을 추천합니다.
    return Size(w * AppConstants.visualSizeScale, h * AppConstants.visualSizeScale);
  }

  static double getUiDiameter(double rawDiameter) {
    // rawDiameter가 0이면 0 반환, 아니면 배율 적용
    return rawDiameter > 0 ? rawDiameter * AppConstants.visualSizeScale : 0;
  }
}
