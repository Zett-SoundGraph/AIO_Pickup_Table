  // lib/services/homography_solver.dart
  import 'package:ml_linalg/matrix.dart';
  import 'package:ml_linalg/dtype.dart';
  import 'package:ml_linalg/vector.dart';
  import 'dart:math';

  class HomographySolver {
    static Matrix solve(List<Point<double>> src, List<Point<double>> dst) {
      if (src.length < 4) throw Exception("최소 4개 이상의 점이 필요합니다.");

      // [핵심] 수치 안정화를 위한 스케일링 (0~1 범위로 압축)
      const double sS = 1.0 / 640.0;  // 센서 최대치
      const double sD = 1.0 / 1920.0; // UI 최대치

      List<List<double>> aList = [];
      List<double> bList = [];

      for (int i = 0; i < src.length; i++) {
        // 숫자를 작게 만들어 연산 정밀도 확보
        double x = src[i].x * sS;
        double y = src[i].y * sS;
        double u = dst[i].x * sD;
        double v = dst[i].y * sD;

        aList.add([x, y, 1, 0, 0, 0, -x * u, -y * u]);
        bList.add(u);
        aList.add([0, 0, 0, x, y, 1, -x * v, -y * v]);
        bList.add(v);
      }

      final A = Matrix.fromList(aList, dtype: DType.float64);
      final B = Matrix.fromColumns([Vector.fromList(bList, dtype: DType.float64)], dtype: DType.float64);

      // 정규 방정식: h = (A^T * A)^-1 * A^T * B
      final At = A.transpose();
      final AtA = At * A;

      // 역행렬 계산 (숫자가 작아져서 이제 매우 안정적입니다)
      final h = AtA.inverse() * At * B;
      final fH = h.getColumn(0);

      // [복원] 정규화했던 수치를 다시 UI 픽셀 단위로 복구
      double h0 = fH[0] * (sS / sD);
      double h1 = fH[1] * (sS / sD);
      double h2 = fH[2] / sD;
      double h3 = fH[3] * (sS / sD);
      double h4 = fH[4] * (sS / sD);
      double h5 = fH[5] / sD;
      double h6 = fH[6] * sS;
      double h7 = fH[7] * sS;

      return Matrix.fromList([
        [h0, h1, h2],
        [h3, h4, h5],
        [h6, h7, 1.0],
      ], dtype: DType.float64);
    }
  }