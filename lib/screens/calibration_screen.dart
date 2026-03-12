  // lib/screens/calibration_screen.dart
  import 'dart:async';
  import 'dart:math' as math;

  import 'package:flutter/material.dart';
  import 'package:ml_linalg/matrix.dart';

  import '../config/app_constants.dart';
  import '../services/coordinate_transformer.dart';
  import '../services/homography_solver.dart';

  class CalibrationPair {
    final Offset src; // 센서 Raw (x, y)
    final double z;
    final Offset dst; // 화면 UI (u, v)
    Offset residual;
    CalibrationPair(this.src, this.z, this.dst, {this.residual = Offset.zero});
  }

  class CalibrationScreen extends StatefulWidget {
    final Offset? currentRawPos; // 메인에서 넘겨주는 실시간 Raw 좌표
    final double? currentRawZ;
    final Function(List<CalibrationPair>) onComplete;
    final VoidCallback onCancel;
    final VoidCallback? onEnterFineTune;
    final VoidCallback? onValidationEntered;
    final VoidCallback? onCalibExit;

    const CalibrationScreen({
      super.key,
      this.currentRawPos,
      this.currentRawZ,
      required this.onComplete,
      required this.onCancel,
      this.onEnterFineTune,
      this.onValidationEntered,
      this.onCalibExit,
    });

    @override
    State<CalibrationScreen> createState() => CalibrationScreenState();
  }

  class CalibrationScreenState extends State<CalibrationScreen> {
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
    bool _hasFinishedFineTuning = false;

    // 디스플레이상의 9개 목표 지점 (1920x1080 기준 적정 마진 적용)
    final List<Offset> targetPoints = [
      const Offset(960, 540), const Offset(150, 150), const Offset(1770, 150),
      const Offset(1770, 930), const Offset(150, 930), const Offset(960, 150),
      const Offset(1770, 540), const Offset(960, 930), const Offset(150, 540),
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
        bool currentlyInside = dist < 0.32;

        if (_isInsideTarget != currentlyInside) setState(() => _isInsideTarget = currentlyInside);

        if (currentlyInside) {
          // [개선] lastStablePos가 없어도(첫 프레임이어도) 일단 타이머 시작 시도
          if (_lastStablePos == null) {
            _lastStablePos = newPos;
            if (!_isCountingDown) _startTimer(); // 첫 프레임에 즉시 시작
            return;
          }

          // 이후 데이터가 들어올 때 '안정적(움직임 적음)'이면 타이머 유지
          if ((newPos - _lastStablePos!).distance < 8.0) { // 감도 8.0 -> 15.0으로 완화
            if (!_isCountingDown) _startTimer();
          } else {
            // 많이 움직이면 타이머 리셋
            _lastStablePos = newPos;
            _resetTimer();
          }
        } else {
          _resetTimer();
          _lastStablePos = null; // 원 밖으로 나가면 초기화
        }
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
          if (_lastStablePos == null) {
            _lastStablePos = newPos;
            if (!_isCountingDown) _startValidationTimer(currentTrigger); // 즉시 시작
            return;
          }
          // 안정성 체크 (감도를 15.0으로 완화하여 미세한 떨림에도 취소되지 않게 함)
          if ((newPos - _lastStablePos!).distance < 15.0) {
            if (!_isCountingDown) _startValidationTimer(currentTrigger);
          } else {
            _lastStablePos = newPos;
            _resetTimer();
          }
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
            // [핵심] 미세 조정을 했느냐에 따라 다음 단계 결정
            if (!_hasFinishedFineTuning) {
              setState(() {
                _isFineTuningMode = true; // 미세 조정 화면으로 이동
                _isCountingDown = false;
              });
              _updateTransformerPreview();
              widget.onEnterFineTune?.call();
            } else {
              widget.onCalibExit?.call();
              widget.onComplete(collectedPairs); // 최종 저장 및 종료
            }
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
      double rawZ = (widget.currentRawZ) ?? AppConstants.totalSensorHeight;
      double currentZ = rawZ;
      debugPrint("📸 [CALIB_STEP ${currentStep + 1}] "
          "Raw(${widget.currentRawPos!.dx.toInt()}, ${widget.currentRawPos!.dy.toInt()}) | "
          "Z: ${widget.currentRawZ?.toStringAsFixed(1)}mm");
      setState(() {
        collectedPairs.add(CalibrationPair(widget.currentRawPos!, currentZ, targetPoints[currentStep]));
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
        // 1. [핵심] 업체 데이터 기반으로 focalLength 고정 (더 이상 찾지 않음)
        final double fixedFL = CoordinateTransformer.focalLength;

        debugPrint("🎯 [Auto-Solver] Fixed FocalLength Applied: $fixedFL mm");

        // 2. 보정된 소스 좌표 생성 (320.0 기준으로 시차 보정 수행)
        final List<math.Point<double>> src = collectedPairs.map((p) {
          Offset corrected = CoordinateTransformer.getParallaxCorrectedOffset(p.src.dx, p.src.dy, p.z);
          return math.Point(corrected.dx, corrected.dy);
        }).toList();

        final List<double> zs = collectedPairs.map((p) => p.z).toList();
        final List<math.Point<double>> dst = collectedPairs.map((p) => math.Point(p.dst.dx, p.dst.dy)).toList();

        // 3. 호모그래피 행렬 계산
        final Matrix hMatrix = HomographySolver.solve(src, zs, dst);

        // 4. 계산된 행렬을 Transformer에 즉시 반영
        List<double> matrixValues = [
          hMatrix[0][0], hMatrix[0][1], hMatrix[0][2],
          hMatrix[1][0], hMatrix[1][1], hMatrix[1][2],
          hMatrix[2][0], hMatrix[2][1], hMatrix[2][2],
        ];
        CoordinateTransformer.setHomographyMatrix(matrixValues);

        CoordinateTransformer.updateResiduals(
            collectedPairs.map((p) => p.residual).toList()
        );

        // 5. 검증용 결과 좌표들 계산
        _transformedPoints.clear();
        _errors.clear();

        for (var pair in collectedPairs) {
          Offset transformed = CoordinateTransformer.transform(
              pair.src.dx,
              pair.src.dy,
              pair.z
          );

          _transformedPoints.add(transformed);
          _errors.add((transformed - pair.dst).distance);
        }

        setState(() => _isValidationMode = true);
        widget.onValidationEntered?.call();
      } catch (e) {
        debugPrint("❌ Validation Error: $e");
        _restartCalibration();
      }
    }

    void _restartCalibration() {
      setState(() {
        currentStep = 0;
        collectedPairs.clear();
        _isValidationMode = false;
        _isCountingDown = false;
        _isFineTuningMode = false;        // 👈 추가: 미세조정 모드 해제
        _hasFinishedFineTuning = false;   // 👈 핵심: 미세조정 완료 플래그 초기화
        _selectedFineTuneIndex = 0;
      });
      widget.onValidationEntered?.call();
    }

    void externalSelectPoint(int index) {
      setState(() => _selectedFineTuneIndex = index);
    }

    void externalAdjust(double dx, double dy) {
      _adjustResidual(dx, dy);
    }

    void externalEnterFineTune() {
      setState(() {
        _isFineTuningMode = true;
        _updateTransformerPreview();
      });
    }

    void externalComplete() {
      setState(() {
        _isFineTuningMode = false;
        _hasFinishedFineTuning = true;
        _enterValidationMode();
      });
    }

    @override
    void dispose() {
      _countdownTimer?.cancel();
      super.dispose();
    }

    @override
    Widget build(BuildContext context) {
      if (_isFineTuningMode) return _buildFineTuneView();
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
      String actionLabel = _hasFinishedFineTuning ? "APPLY & EXIT" : "FINE-TUNE";
      Color actionColor = _hasFinishedFineTuning ? Colors.cyanAccent : Colors.orangeAccent;
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
              Positioned(
                left: targetPoints[i].dx - 50,
                top: targetPoints[i].dy + 65, // 오차 텍스트보다 살짝 아래
                width: 100,
                child: Center(
                  child: Text(
                    "Z: ${collectedPairs[i].z.toInt()}mm",
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      backgroundColor: Colors.black54,
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
              label: actionLabel, // "FINE-TUNE" 또는 "APPLY & EXIT"
              color: actionColor, // 주황색 또는 청록색
              isActive: _activeValidationTrigger == 1,
            ),
          ],
        ),
      );
    }

    Widget _buildFineTuneView() {
      return Container(
        color: Colors.black,
        child: Stack(
          children: [
            // 1. 배경 가이드 (9개 포인트 표시 및 선택)
            for (int i = 0; i < 9; i++)
              Positioned(
                left: targetPoints[i].dx - 60,
                top: targetPoints[i].dy - 60,
                child: GestureDetector(
                  onTap: () => setState(() => _selectedFineTuneIndex = i),
                  child: Container(
                    width: 120, height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _selectedFineTuneIndex == i ? Colors.orangeAccent : Colors.white24,
                        width: _selectedFineTuneIndex == i ? 5 : 2,
                      ),
                    ),
                    child: Center(child: Text("${i + 1}", style: const TextStyle(color: Colors.white))),
                  ),
                ),
              ),

            // 2. 실시간 프리뷰 원 (현재 조정값이 반영된 결과)
            Positioned(
              left: _transformedPoints[_selectedFineTuneIndex].dx - 45,
              top: _transformedPoints[_selectedFineTuneIndex].dy - 45,
              child: Container(
                width: 90, height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.orangeAccent.withOpacity(0.3),
                  border: Border.all(color: Colors.orangeAccent, width: 3),
                ),
              ),
            ),

            // 3. 미세 조정 컨트롤러 (기존에 작성하신 메서드 호출)
            _buildFineTuneControls(),
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
    bool _isFineTuningMode = false;
    int _selectedFineTuneIndex = 0; // 현재 미세 조정 중인 포인트 (0~8)

// 미세 조정 핸들러
    void _adjustResidual(double dx, double dy) {
      setState(() {
        Offset current = collectedPairs[_selectedFineTuneIndex].residual;
        collectedPairs[_selectedFineTuneIndex].residual = current + Offset(dx, dy);

        _updateTransformerPreview();

        _transformedPoints[_selectedFineTuneIndex] = CoordinateTransformer.transform(
          collectedPairs[_selectedFineTuneIndex].src.dx,
          collectedPairs[_selectedFineTuneIndex].src.dy,
          collectedPairs[_selectedFineTuneIndex].z,
        );

        _errors[_selectedFineTuneIndex] = (_transformedPoints[_selectedFineTuneIndex] - targetPoints[_selectedFineTuneIndex]).distance;
      });
    }

    void _updateTransformerPreview() {
      // 현재까지의 행렬 + 미세 조정값들을 Transformer에 임시 주입
      // transform() 함수가 이 값들을 참조하여 실시간으로 결과를 보여줌
      CoordinateTransformer.updateResiduals(
          collectedPairs.map((p) => p.residual).toList()
      );
    }

// UI 빌더에서 미세 조정 컨트롤러 추가
    Widget _buildFineTuneControls() {
      return Positioned(
        bottom: 30, left: 0, right: 0,
        child: Center(
          child: Text("KDS 통해 보정을 진행해주세요.",
              style: TextStyle(color: Colors.orangeAccent, fontSize: 18)),
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