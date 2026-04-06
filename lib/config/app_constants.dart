class AppConstants {
  static const int serverPort = 8080;
  static const bool isDebug = true;

  static const double sensorWidth = 640.0;
  static const double sensorHeight = 480.0;
  static const double sensorCenterX = 320.0;
  static const double sensorCenterY = 240.0;

  // [매장별 커스텀 설정 - 이 부분을 매장마다 수정]
  static double totalSensorHeight = 1000.0; // 천장에서 바닥까지 높이 (mm)

  static const double visualSizeScale = 3.17;
}