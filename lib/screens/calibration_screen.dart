// lib/screens/calibration_screen.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ml_linalg/matrix.dart';

import '../config/app_constants.dart';
import '../services/homography_solver.dart';

class CalibrationPair {
  final Offset src; // 센서 Raw (x, y)
  final Offset dst; // 화면 UI (u, v)
  CalibrationPair(this.src, this.dst);
}

class CalibrationScreen extends StatefulWidget {
  final Offset? currentRawPos; // 메인에서 넘겨주는 실시간 Raw 좌표
  final Function(List<CalibrationPair>) onComplete;
  final VoidCallback onCancel;

  const CalibrationScreen({
    super.key,
    this.currentRawPos,
    required this.onComplete,
    required this.onCancel,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  int currentStep = 0;
  List<CalibrationPair> collectedPairs = [];

  Timer? _countdownTimer;
  int _secondsRemaining = 3;
  bool _isCountingDown = false;
  Offset? _lastStablePos;
  bool _isInsideTarget = false;
  bool _isValidationMode = false;
  List<Offset> _transformedPoints = []; // 계산된 결과 좌표들
  List<double> _errors = [];
  int _activeValidationTrigger = -1;

  // 디스플레이상의 9개 목표 지점 (1920x1080 기준 적정 마진 적용)
  final List<Offset> targetPoints = [
    const Offset(150, 150),   const Offset(960, 150),   const Offset(1770, 150),
    const Offset(150, 540),   const Offset(960, 540),   const Offset(1770, 540),
    const Offset(150, 930),   const Offset(960, 930),   const Offset(1770, 930),
  ];

  @override
  void didUpdateWidget(CalibrationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentRawPos != null) {
      _checkStabilityAndProximity(widget.currentRawPos!);
    } else {
      _isInsideTarget = false;
      _activeValidationTrigger = -1;
      _resetTimer();
    }
  }

  final Offset _restartTriggerPos = const Offset(555, 540); // 4번(150)과 5번(960)의 중간
  final Offset _applyTriggerPos = const Offset(1365, 540);  // 5번(960)과 6번(1770)의 중간

  // 현재 어떤 버튼 위에 컵이 있는지 확인 (0: RESTART, 1: APPLY, -1: NONE)

  void _checkStabilityAndProximity(Offset newPos) {
    if (!_isValidationMode) {
      // --- [기존] 9포인트 캘리브레이션 모드 로직 ---
      double normRawX = newPos.dx / (AppConstants.sensorCenterX * 2);
      double normRawY = newPos.dy / (AppConstants.sensorCenterY * 2);
      double normTargetX = targetPoints[currentStep].dx / 1920.0;
      double normTargetY = targetPoints[currentStep].dy / 1080.0;

      double dist = math.sqrt(math.pow(normRawX - normTargetX, 2) + math.pow(normRawY - normTargetY, 2));
      bool currentlyInside = dist < 0.28;

      if (_isInsideTarget != currentlyInside) setState(() => _isInsideTarget = currentlyInside);

      if (currentlyInside) {
        if (_lastStablePos == null) { _lastStablePos = newPos; return; }
        if ((newPos - _lastStablePos!).distance < 8.0) {
          if (!_isCountingDown) _startTimer();
        } else { _lastStablePos = newPos; _resetTimer(); }
      } else { _resetTimer(); }
    } else {
      // --- [신규] 검증(Validation) 모드 자동화 로직 ---
      double normRawX = newPos.dx / (AppConstants.sensorCenterX * 2);
      double normRawY = newPos.dy / (AppConstants.sensorCenterY * 2);

      // 두 트리거 버튼에 대한 정규화 거리 계산
      double distRestart = math.sqrt(math.pow(normRawX - (_restartTriggerPos.dx / 1920.0), 2) + math.pow(normRawY - (540 / 1080.0), 2));
      double distApply = math.sqrt(math.pow(normRawX - (_applyTriggerPos.dx / 1920.0), 2) + math.pow(normRawY - (540 / 1080.0), 2));

      int currentTrigger = -1;
      if (distRestart < 0.20) currentTrigger = 0;
      else if (distApply < 0.20) currentTrigger = 1;

      if (_activeValidationTrigger != currentTrigger) {
        setState(() => _activeValidationTrigger = currentTrigger);
        _resetTimer(); // 버튼을 옮기면 타이머 초기화
      }

      if (currentTrigger != -1) {
        if (_lastStablePos == null) { _lastStablePos = newPos; return; }
        if ((newPos - _lastStablePos!).distance < 8.0) {
          if (!_isCountingDown) _startValidationTimer(currentTrigger);
        } else { _lastStablePos = newPos; _resetTimer(); }
      } else {
        _resetTimer();
      }
    }
  }

  void _startValidationTimer(int triggerIndex) {
    setState(() {
      _isCountingDown = true;
      _secondsRemaining = 3;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 1) {
        setState(() => _secondsRemaining--);
      } else {
        timer.cancel();
        if (triggerIndex == 0) {
          _restartCalibration(); // RESTART 실행
        } else {
          widget.onComplete(collectedPairs); // APPLY & EXIT 실행
        }
      }
    });
  }

  void _startTimer() {
    setState(() {
      _isCountingDown = true;
      _secondsRemaining = 3;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 1) {
        setState(() => _secondsRemaining--);
      } else {
        _handleAutoCapture();
      }
    });
  }

  void _resetTimer() {
    if (_isCountingDown) {
      _countdownTimer?.cancel();
      setState(() {
        _isCountingDown = false;
        _secondsRemaining = 3;
      });
    }
  }

  void _handleAutoCapture() {
    _countdownTimer?.cancel();
    if (widget.currentRawPos == null) return;

    setState(() {
      collectedPairs.add(CalibrationPair(widget.currentRawPos!, targetPoints[currentStep]));
      _isCountingDown = false;
      _secondsRemaining = 3;
      _lastStablePos = null;

      if (currentStep < targetPoints.length - 1) {
        currentStep++;
      } else {
        // [수정] 9단계 완료 시 즉시 종료하지 않고 검증 모드로 진입
        _enterValidationMode();
      }
    });
  }

  void _enterValidationMode() {
    try {
      // 1. 현재까지 모인 9개 점으로 호모그래피 행렬 계산
      final List<math.Point<double>> src = collectedPairs.map((p) => math.Point(p.src.dx, p.src.dy)).toList();
      final List<math.Point<double>> dst = collectedPairs.map((p) => math.Point(p.dst.dx, p.dst.dy)).toList();
      final Matrix hMatrix = HomographySolver.solve(src, dst);

      // 2. 계산된 행렬로 Raw 좌표를 다시 UI 좌표로 변환해보기 (결과 확인용)
      _transformedPoints.clear();
      _errors.clear();

      for (var pair in collectedPairs) {
        double den = hMatrix[2][0] * pair.src.dx + hMatrix[2][1] * pair.src.dy + hMatrix[2][2];
        double tx = (hMatrix[0][0] * pair.src.dx + hMatrix[0][1] * pair.src.dy + hMatrix[0][2]) / den;
        double ty = (hMatrix[1][0] * pair.src.dx + hMatrix[1][1] * pair.src.dy + hMatrix[1][2]) / den;

        Offset transformed = Offset(tx, ty);
        _transformedPoints.add(transformed);
        _errors.add((transformed - pair.dst).distance); // 목표점과의 오차(px)
      }

      setState(() {
        _isValidationMode = true;
      });
    } catch (e) {
      debugPrint("Validation Error: $e");
      // 에러 시 재시작 유도
      _restartCalibration();
    }
  }

  void _restartCalibration() {
    setState(() {
      currentStep = 0;
      collectedPairs.clear();
      _isValidationMode = false;
      _isCountingDown = false;
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isValidationMode) return _buildValidationView();
    Color activeColor = _isCountingDown ? Colors.greenAccent : Colors.redAccent;
    return Container(
      color: Colors.black.withOpacity(0.95),
      child: Stack(
        children: [
          _buildTopGuide(activeColor),
          _buildTargetCircle(activeColor),
          //_buildMinimap(activeColor),
        ],
      ),
    );
  }
  Widget _buildValidationView() {
    return Container(
      // 배경색을 약간 투명하게 하여 메인 화면이 살짝 보이게 할 수도 있습니다.
      color: Colors.black.withOpacity(0.98),
      child: Stack(
        children: [
          // 1. 상단 타이틀
          const Positioned(
            top: 60, left: 0, right: 0,
            child: Center(
              child: Text("CALIBRATION RESULT",
                  style: TextStyle(color: Colors.cyanAccent, fontSize: 40, fontWeight: FontWeight.bold)),
            ),
          ),

          // 2. 오차 선 (화면 전체에 한 번에 그리기 위해 Positioned.fill 사용)
          Positioned.fill(
            child: CustomPaint(
              painter: AllErrorLinesPainter(
                targets: targetPoints,
                results: _transformedPoints,
              ),
            ),
          ),

          // 3. 각 지점별 목표/결과 포인트 (중첩 Stack 제거)
          for (int i = 0; i < 9; i++) ...[
            // 목표 위치 (회색 점선 원 느낌)
            Positioned(
              left: targetPoints[i].dx - 40,
              top: targetPoints[i].dy - 40,
              child: Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white10, width: 2),
                ),
              ),
            ),

            // 결과 위치 (실제 계산된 점)
            Positioned(
              left: _transformedPoints[i].dx - 10,
              top: _transformedPoints[i].dy - 10,
              child: Container(
                width: 20, height: 20,
                decoration: BoxDecoration(
                  color: _errors[i] < 15.0 ? Colors.greenAccent : Colors.orangeAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (_errors[i] < 15.0 ? Colors.greenAccent : Colors.orangeAccent).withOpacity(0.5),
                      blurRadius: 10,
                    )
                  ],
                ),
              ),
            ),

            // 오차 수치 텍스트
            Positioned(
              left: targetPoints[i].dx - 50,
              top: targetPoints[i].dy + 45,
              width: 100,
              child: Center(
                child: Text(
                  "${_errors[i].toStringAsFixed(1)}px",
                  style: TextStyle(
                    color: _errors[i] < 15.0 ? Colors.greenAccent : Colors.orangeAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    backgroundColor: Colors.black45,
                  ),
                ),
              ),
            ),
          ],

          _buildActionTrigger(
            position: _restartTriggerPos,
            label: "RESTART",
            color: Colors.redAccent,
            isActive: _activeValidationTrigger == 0,
          ),

          // [신규] 자동화 트리거 서클 (APPLY 존)
          _buildActionTrigger(
            position: _applyTriggerPos,
            label: "APPLY & EXIT",
            color: Colors.cyanAccent,
            isActive: _activeValidationTrigger == 1,
          ),
        ],
      ),
    );
  }

  Widget _buildActionTrigger({
    required Offset position,
    required String label,
    required Color color,
    required bool isActive, // 컵이 영역 안에 있음
  }) {
    // [수정] 카운트다운 중일 때만 액티브 색상을 쓰고, 아니면 희미한 흰색(대기) 처리
    bool isTriggered = isActive && _isCountingDown;
    Color displayColor = isTriggered ? color : Colors.white24;

    return Positioned(
      left: position.dx - 100,
      top: position.dy - 100,
      child: Column(
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: displayColor,
                width: isTriggered ? 8 : 2, // 카운트다운 시작 시 테두리 강조
              ),
              boxShadow: [
                if (isTriggered) BoxShadow(color: color.withOpacity(0.4), blurRadius: 40)
              ],
            ),
            child: Center(
              child: isTriggered
                  ? Text("$_secondsRemaining", style: TextStyle(color: color, fontSize: 60, fontWeight: FontWeight.bold))
                  : Icon(isActive ? Icons.pan_tool : Icons.radio_button_unchecked, color: displayColor, size: 50),
            ),
          ),
          const SizedBox(height: 20),
          Text(label, style: TextStyle(color: displayColor, fontSize: 24, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildTopGuide(Color activeColor) {
    return Positioned(
      top: 100, left: 0, right: 0,
      child: Column(
        children: [
          Text("Calibration Step ${currentStep + 1} / 9",
              style: TextStyle(color: activeColor, fontSize: 32, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(
              _isCountingDown
                  ? "$_secondsRemaining초 후 캡처됩니다!" // 카운트다운 중
                  : "컵을 붉은 원 안으로 옮겨주세요.",        // 평상시
              style: TextStyle(color: activeColor.withOpacity(0.8), fontSize: 18)
          ),
        ],
      ),
    );
  }

  Widget _buildTargetCircle(Color activeColor) { /* 기존 원형 타겟 로직 */
    return Positioned(
      left: targetPoints[currentStep].dx - 75, top: targetPoints[currentStep].dy - 75,
      child: Container(
        width: 150, height: 150,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: activeColor, width: _isInsideTarget ? 8 : 4)),
        child: Center(child: _isCountingDown
            ? Text("$_secondsRemaining", style: TextStyle(color: activeColor, fontSize: 60, fontWeight: FontWeight.bold))
            : Icon(_isInsideTarget ? Icons.pan_tool : Icons.ads_click, color: activeColor, size: 40)),
      ),
    );
  }

  Widget _buildMinimap(Color activeColor) { /* 기존 미니맵 로직 */
    return Positioned(
      top: 40, left: 40,
      child: Container(
        width: 160, height: 120,
        decoration: BoxDecoration(color: Colors.white10, border: Border.all(color: Colors.white24, width: 1), borderRadius: BorderRadius.circular(4)),
        child: Stack(children: [
          const Center(child: Text("SENSOR RAW", style: TextStyle(color: Colors.white24, fontSize: 10))),
          if (widget.currentRawPos != null) Positioned(
            left: (widget.currentRawPos!.dx / 640) * 160 - 4, top: (widget.currentRawPos!.dy / 480) * 120 - 4,
            child: Container(width: 8, height: 8, decoration: BoxDecoration(color: activeColor, shape: BoxShape.circle)),
          ),
        ]),
      ),
    );
  }
}

class AllErrorLinesPainter extends CustomPainter {
  final List<Offset> targets;
  final List<Offset> results;

  AllErrorLinesPainter({required this.targets, required this.results});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < targets.length; i++) {
      // 목표점과 결과점 사이에 선 긋기
      canvas.drawLine(targets[i], results[i], paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}