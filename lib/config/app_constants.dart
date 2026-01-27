class AppConstants {
  static const int serverPort = 8080;
  static const bool isDebug = true;

  // [ToF 센서 기본 사양]
  static const double sensorCenterX = 320.0; // 센서 가로 해상도의 절반
  static const double sensorCenterY = 240.0; // 센서 세로 해상도의 절반

  // [매장별 커스텀 설정 - 이 부분을 매장마다 수정]
  static double totalSensorHeight = 1000.0; // 천장에서 바닥까지 높이 (mm)

  // [실측 데이터 반영] 기존 3.17 배율에 카메라 렌즈 배율을 각각 적용
  static const double scaleX = 3.32;
  static const double scaleY = 3.26;

  // Skew 값은 일단 유지하며 테스트 후 필요시 미세 조정
  static const double rotationSkew = 0.058;

  // 시작점 오프셋 (테스트 결과에 따라 다시 가감 필요)
  static const double offsetX = 258.0;
  static const double offsetY = 168.0;
}