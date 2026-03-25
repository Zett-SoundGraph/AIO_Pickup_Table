import 'dart:math';
import 'dart:ui';
import 'package:ml_linalg/matrix.dart';
import 'package:ml_linalg/dtype.dart';
import 'package:ml_linalg/vector.dart';
import '../config/app_constants.dart';
import 'coordinate_transformer.dart';

class PolynomialSolver {
  static Map<String, List<double>> solveAll(List<Point<double>> src, List<double> zs, List<Point<double>> dst) {
    // 순방향: 센서(640x480) -> UI(1920x1080)
    List<double> forward = _calculate(src, zs, dst, isForward: true);
    // 역방향: UI(1920x1080) -> 센서(640x480)
    List<double> inverse = _calculate(dst, List.filled(dst.length, AppConstants.totalSensorHeight), src, isForward: false);

    return {
      'forward': forward,
      'inverse': inverse,
    };
  }

  static List<double> _calculate(List<Point<double>> input, List<double> zs, List<Point<double>> output, {required bool isForward}) {
    List<List<double>> aRows = [];
    List<double> bx = [];
    List<double> by = [];

    // 정규화 스케일 (수치 폭발 방지)
    double scaleX = isForward ? 1.0 / 640.0 : 1.0 / 1920.0;
    double scaleY = isForward ? 1.0 / 480.0 : 1.0 / 1080.0;
    double outScaleX = isForward ? 1.0 / 1920.0 : 1.0 / 640.0;
    double outScaleY = isForward ? 1.0 / 1080.0 : 1.0 / 480.0;

    for (int i = 0; i < input.length; i++) {
      double rawX = input[i].x;
      double rawY = input[i].y;
      double z = zs[i];

      if (isForward) {
        // 순방향일 때만 시차 보정 적용
        Offset g = CoordinateTransformer.getFixedParallax(rawX, rawY, z);
        rawX = g.dx; rawY = g.dy;
      }

      double x = rawX * scaleX;
      double y = rawY * scaleY;

      aRows.add([1.0, x, y, x * y, x * x, y * y]);
      bx.add(output[i].x * outScaleX);
      by.add(output[i].y * outScaleY);
    }

    // 🌟 모든 생성 시 dtype: DType.float64를 명시하여 충돌 방지
    final A = Matrix.fromList(aRows, dtype: DType.float64);
    final At = A.transpose();

    // 최소자승법 연산: (At * A)^-1 * At
    final AtA = At * A;
    final AtA_inv = AtA.inverse();
    final sol = AtA_inv * At;

    // 결과 벡터를 행렬로 변환할 때도 dtype 강제
    final Bx = Matrix.fromColumns([Vector.fromList(bx, dtype: DType.float64)], dtype: DType.float64);
    final By = Matrix.fromColumns([Vector.fromList(by, dtype: DType.float64)], dtype: DType.float64);

    // 행렬 곱셈 수행
    final Wx = sol * Bx;
    final Wy = sol * By;

    final ax = Wx.getColumn(0).toList();
    final ay = Wy.getColumn(0).toList();

    return [...ax, ...ay];
  }
}