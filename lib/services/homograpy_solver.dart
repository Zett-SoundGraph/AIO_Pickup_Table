import 'dart:math';
import 'dart:ui';
import 'package:ml_linalg/matrix.dart';
import 'package:ml_linalg/dtype.dart';
import 'package:ml_linalg/vector.dart';
import '../config/app_constants.dart';
import 'coordinate_transformer.dart';

class HomographySolver {
  /// 9개의 점을 바탕으로 3x3 호모그래피 행렬(9개 계수)을 산출합니다.
  static List<double> solve(List<Point<double>> src, List<double> zs, List<Point<double>> dst) {
    List<List<double>> aRows = [];
    List<double> bValues = [];

    for (int i = 0; i < src.length; i++) {
      // 1. 입력 좌표를 먼저 물리적 '바닥면' 좌표로 변환 (중요!)
      Offset floor = CoordinateTransformer.getFloorProjectedOffset(src[i].x, src[i].y, zs[i]);
      double x = floor.dx;
      double y = floor.dy;
      double u = dst[i].x;
      double v = dst[i].y;

      // 2. 호모그래피 방정식을 위한 행렬 구성 (u = (h0x + h1y + h2) / (h6x + h7y + 1))
      // Row 1: x, y, 1, 0, 0, 0, -ux, -uy
      aRows.add([x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y]);
      bValues.add(u);

      // Row 2: 0, 0, 0, x, y, 1, -vx, -vy
      aRows.add([0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y]);
      bValues.add(v);
    }

    final A = Matrix.fromList(aRows, dtype: DType.float64);
    final B = Vector.fromList(bValues, dtype: DType.float64);

    // 최소자승법: (At * A)^-1 * At * B
    final At = A.transpose();
    final AtA = At * A;
    final AtA_inv = AtA.inverse();
    final sol = AtA_inv * At * Matrix.fromColumns([B], dtype: DType.float64);

    List<double> res = sol.getColumn(0).toList();
    res.add(1.0); // h8 값은 1.0으로 고정

    return res; // [h0, h1, h2, h3, h4, h5, h6, h7, h8]
  }
}