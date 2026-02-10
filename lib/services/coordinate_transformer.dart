import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';

import '../config/app_constants.dart';

class CoordinateTransformer {
  // 1. 호모그래피 행렬 저장 변수 (초기값은 변환이 없는 '단위 행렬')
  static List<double> _h = [1, 0, 0, 0, 1, 0, 0, 0, 1];

  // 2. 행렬 업데이트 함수 (Calibration 완료 후 호출됨)
  static void setHomographyMatrix(List<double> matrix) {
    _h = matrix;
    print("🎯 CoordinateTransformer: 새로운 호모그래피 행렬이 적용되었습니다.");
  }
  static void resetMatrix() {
    _h = [1, 0, 0, 0, 1, 0, 0, 0, 1];
    debugPrint("🔄 [Transformer] 행렬이 초기화되었습니다. (Collapse 현상 방지)");
  }

  static Offset getParallaxCorrectedOffset(double rawX, double rawY, double zValue) {
    // 1. 기본 비율 계산
    double ratio = zValue / AppConstants.totalSensorHeight;

    // 2. [정밀 튜닝] 축별 보정 강도(Gain) 적용
    // X는 너무 좁아지므로 1.0보다 크게(덜 좁히기), Y는 너무 벌어지므로 1.0보다 작게(더 당기기)
    const double gainX = 1.015; // 가로 수축 방지 (1.5% 확장)
    const double gainY = 0.980; // 세로 과확장 방지 (2.0% 축소)

    // 3. 중심점(320, 240) 기준 보정 수행
    double px = (rawX - AppConstants.sensorCenterX) * (ratio * gainX) + AppConstants.sensorCenterX;
    double py = (rawY - AppConstants.sensorCenterY) * (ratio * gainY) + AppConstants.sensorCenterY;

    return Offset(px, py);
  }

  static bool _isFirstHeightSet = false;
  static void updateFloorHeight(double rawZ) {
    // 1. 센서가 측정한 광학적 바닥 높이(예: 1016)를 그대로 신뢰합니다.
    double currentHeight = AppConstants.totalSensorHeight;
    double diff = (rawZ - currentHeight).abs();

    // 2. [최적화] 첫 실행이거나, 변화량이 5mm 이상일 때만 업데이트
    if (!_isFirstHeightSet || diff >= 5.0) {
      AppConstants.totalSensorHeight = rawZ;
      _isFirstHeightSet = true;

      debugPrint("📢 [Sensor Sync] 바닥 높이(base_z) 확정: ${rawZ.toStringAsFixed(1)}mm");
      if (diff >= 5.0 && _isFirstHeightSet) {
        debugPrint("⚠️ 환경 변화 감지 (차이: ${diff.toStringAsFixed(1)}mm)");
      }
    }
  }

  static Offset transform(double rawX, double rawY, double zValue) {
    // 1. 시차 보정 수행
    Offset p = getParallaxCorrectedOffset(rawX, rawY, zValue);

    // 2. 호모그래피 변환 (단순하고 강력한 수식으로 복구)
    double den = _h[6] * p.dx + _h[7] * p.dy + _h[8];
    if (den == 0) den = 1.0; // 분모 0 방지

    double finalX = (_h[0] * p.dx + _h[1] * p.dy + _h[2]) / den;
    double finalY = (_h[3] * p.dx + _h[4] * p.dy + _h[5]) / den;

    return Offset(finalX, finalY);
  }

  static Size getUiSize(double rawWidth, double rawHeight) {
    double w = (rawWidth > 0) ? rawWidth : 80.0;
    double h = (rawHeight > 0) ? rawHeight : 80.0;

    // 크기 변환용 배율은 행렬의 평균 스케일을 추출해 쓸 수도 있으나,
    // 일관성을 위해 기존에 검증된 scaleX(3.17 등)를 상수로 유지하는 것을 추천합니다.
    return Size(w * AppConstants.scaleX, h * AppConstants.scaleX);
  }

  static double getUiDiameter(double rawDiameter) {
    // rawDiameter가 0이면 0 반환, 아니면 배율 적용
    return rawDiameter > 0 ? rawDiameter * AppConstants.scaleX : 0;
  }
}