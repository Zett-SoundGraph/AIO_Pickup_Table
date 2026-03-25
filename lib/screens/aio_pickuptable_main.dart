import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:aio_pickup_table/components/guide_circle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ml_linalg/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../components/animation_kit.dart';
import '../components/arc_text_painter.dart';
import '../components/hand_detection_overlay.dart';
import '../services/coordinate_transformer.dart';
import '../services/Polynomial_solver.dart';
import '../services/order_manager.dart';
import '../services/socket_server_service.dart';
import '../models/pickup_data.dart';
import '../config/app_constants.dart';
import 'calibration_screen.dart';

class LogItem {
  final String timestamp; // 시간
  final String type; // RX, TX, SYS, MOVE 등
  final String message; // 로그 내용
  final int? frameId; // 프레임 ID (색상 구분용, null이면 시스템 로그)
  final int? objectId;

  LogItem({
    required this.timestamp,
    required this.type,
    required this.message,
    this.frameId,
    this.objectId,
  });
}

// UI 표시용 모델
class DetectedObject {
  final int id;
  final String orderNo; // 그룹핑 기준
  final Offset position; // 좌표 (x, y)
  final double zValue; // 높이
  final double diameter; // 지름
  final double uiWidth;
  final double uiHeight;
  final double labelAngle;
  final Color color;

  DetectedObject({
    required this.id,
    required this.orderNo,
    required this.position,
    required this.zValue,
    required this.diameter,
    required this.uiWidth,
    required this.uiHeight,
    this.labelAngle = 1.0,
    required this.color,
  });
}

class AioPickupTableMain extends StatefulWidget {
  const AioPickupTableMain({super.key});

  @override
  State<AioPickupTableMain> createState() => _AioPickupTableMainState();
}

class _AioPickupTableMainState extends State<AioPickupTableMain> {
  late SocketServerService _serverService;
  bool _isCalibrating = false;
  Offset? _latestRawForCalib;
  // 감지된 객체 리스트 (UI용으로 변환된 데이터)
  List<DetectedObject> objects = [];
  List<DetectedObject> exitingObjects = [];
  List<DetectedObject> hands = [];

  // 로그 제어용 변수
  bool _showRawData = true;
  List<TofObject> _lastFrameObjects = [];
  final double _movementThreshold = 2.0;

  bool _isHandDetected = false;
  Timer? _handDetectionTimer;

  Map<String, ui.Image> _iconImages = {};
  int _irValue = 51;
  int? _lastSentIrValue;

  final GlobalKey<CalibrationScreenState> _calibKey = GlobalKey<CalibrationScreenState>();

  void _resetHandDetectionTimer() {
    // 기존 타이머가 있다면 취소
    _handDetectionTimer?.cancel();

    _handDetectionTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && _isHandDetected) {
        setState(() {
          _isHandDetected = false;
          hands = []; // 손 데이터도 초기화
        });
        //_addLog("SYS", "👋 손 감지 시간 초과: 효과 해제", force: true);
      }
    });
  }

  final List<Color> _idPalette = List.generate(100, (index) {
    double hue = (index * 137.508) % 360;

    double saturation = (index % 2 == 0) ? 0.9 : 0.5;

    double value = 1.0 - ((index % 3) * 0.2);

    return HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
  });

  final ValueNotifier<List<Offset>> _obstacleNotifier = ValueNotifier([]);

  int? _currentLatestFrameId;

// ID를 기반으로 색상을 가져오는 헬퍼 함수
  Color _getColorForId(int id) {
    if (id < 0) return Colors.white54;
    return _idPalette[id % _idPalette.length];
  }

  String _getGuideLabel(String orderNo) {
    // 대기열에서 해당 주문번호와 일치하는 데이터를 찾습니다.
    final orderData = OrderManager.waitingQueue.firstWhere(
          (o) => o['orderNo'] == orderNo,
      // 만약 대기열에 없다면(거의 없겠지만 안전하게) 기본 주문번호 반환
      orElse: () => {'nickname': '', 'orderNo': orderNo},
    );
    return _buildComplexLabel(orderData);
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCalibration();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initializeServer();
    _logCurrentServerIp();
    _loadIcons();
    /// ir 값 변경 커멘드
    //Future.delayed(Duration(seconds: 3), () => _sendIrValueToPi(51));
  }

  Future<void> _loadIcons() async {
    _iconImages['☕'] = await _loadImage('assets/images/drink.png');
    _iconImages['🥪'] = await _loadImage('assets/images/food.png');
    _iconImages['🍾'] = await _loadImage('assets/images/bottle.png');
    if (mounted) setState(() {}); // 로드 완료 후 화면 갱신
  }

  Future<ui.Image> _loadImage(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<void> _loadSavedCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    final String? coeffsJson = prefs.getString('polynomial_coeffs');
    if (coeffsJson != null) {
      List<double> coeffs = List<double>.from(jsonDecode(coeffsJson));
      CoordinateTransformer.setPolynomialCoefficients(coeffs);
    }

    // final double? savedFL = prefs.getDouble('focal_length');
    // if (savedFL != null) {
    //   CoordinateTransformer.focalLength = savedFL;
    //   debugPrint("✅ [Load] FocalLength restored: $savedFL");
    // }

    // 2. [추가] 미세 조정 잔차 데이터 불러오기
    final String? residualJson = prefs.getString('calibration_residuals');
    if (residualJson != null) {
      try {
        List<dynamic> decoded = jsonDecode(residualJson);
        List<Offset> residuals = decoded.map((item) =>
            Offset(item['dx'] as double, item['dy'] as double)
        ).toList();

        CoordinateTransformer.updateResiduals(residuals);
        //debugPrint("✅ [Load] Calibration Residuals restored.");
      } catch (e) {
        //debugPrint("❌ [Error] Residuals load failed: $e");
      }
    }
    setState(() {
      _irValue = prefs.getInt('ir_value') ?? 51;
      _lastSentIrValue = _irValue;
    });
  }

  void _sendIrValueToPi(int newValue) async {
    int clampedValue = newValue.clamp(0, 61);
    if (_lastSentIrValue == clampedValue) {
      //debugPrint("⚠️ [IR_CONTROL] 현재 값($clampedValue)이 이전과 동일하여 전송을 스킵합니다. (리부팅 방지)");
      return;
    }
    setState(() => _irValue = clampedValue);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('ir_value', clampedValue);

    // 현재 연결된 모든 클라이언트(라즈베리 파이 포함)에게 전송
    _serverService.sendMessage(jsonEncode({
      "event_type": "set_ir",
      "ir_value": clampedValue,
    }));

    _lastSentIrValue = clampedValue;

    debugPrint("📤 [IR_CONTROL] IR Value Broadcast: $clampedValue");
  }

  String _buildComplexLabel(Map<String, dynamic> info) {
    List<String> icons = [];
    if ((info['drinkCount'] ?? 0) > 0) icons.add("☕${info['drinkCount']}");
    if ((info['foodCount'] ?? 0) > 0) icons.add("🥪${info['foodCount']}");
    if ((info['bottleCount'] ?? 0) > 0) icons.add("🍾${info['bottleCount']}");

    String prefix = icons.isNotEmpty ? "${icons.join(" ")} | " : "";
    String name = (info['nickname'] != null && info['nickname'] != "")
        ? info['nickname']
        : "NO.${info['orderNo']}";

    return "$prefix$name";
  }

  bool _hasSignificantChange(List<TofObject> newObjs, List<TofObject> oldObjs) {
    // 1. 개수가 다르면 무조건 변화 (진입/퇴장)
    if (newObjs.length != oldObjs.length) return true;

    // 2. 개수가 같다면, 위치 이동 체크
    for (var newObj in newObjs) {
      // ID가 같은 이전 객체 찾기
      var oldObj = oldObjs.firstWhere(
        (o) => o.id == newObj.id,
        orElse: () => TofObject(
            id: -1,
            x: 0,
            y: 0,
            z: 0,
            diameter: 0,
            width: 0,
            height: 0,
            isStable: false),
      );

      // (예외 방어) 이전 프레임에 없는 ID가 생겼다면 변화로 간주
      if (oldObj.id == -1) return true;

      // 거리 차이 계산 (피타고라스)
      double dx = newObj.x - oldObj.x;
      double dy = newObj.y - oldObj.y;
      double distance = sqrt(dx * dx + dy * dy);

      // 설정한 임계값보다 많이 움직였으면 변화 있음
      if (distance > _movementThreshold) return true;
    }

    // 위 조건에 걸리지 않으면 '변화 없음(정지 상태)'
    return false;
  }

  // [새로 작성할 함수] 실제 IP를 찾아서 _addLog로 출력
  Future<void> _logCurrentServerIp() async {
    try {
      // 네트워크 인터페이스 목록 조회
      List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (var interface in interfaces) {
        // 내부 루프백(127.0.0.1)이 아닌 실제 통신용 IP 찾기
        var addr = interface.addresses.firstWhere(
          (a) => !a.address.startsWith('127'),
          orElse: () => interface.addresses.first,
        );

        //_addLog("SYS", "========================================", force: true);
        //_addLog("SYS", " WebSocket Server Running ", force: true);
        //_addLog("SYS", " IP Address : ${addr.address} ", force: true);
        //_addLog("SYS", " Port       : ${AppConstants.serverPort} ",
        //    force: true);
        //_addLog("SYS", "========================================", force: true);

        return;
      }
    } catch (e) {
      //_addLog("SYS", "IP 주소 조회 실패: $e", force: true);
    }
  }

  bool _isConsoleOpen = false;
  final List<LogItem> _consoleLogs = [];
  final ScrollController _scrollController = ScrollController();

  final GlobalKey<FloatingVideoLayerState> _videoLayerKey =
      GlobalKey<FloatingVideoLayerState>();
  Timer? _adTimer;

  void _addLog(String type, String message,
      {int? frameId, int? objectId, bool force = false}) {
    if (!mounted) return;
    if (_consoleLogs.length > 50) _consoleLogs.removeAt(0);

    String time = DateTime.now().toIso8601String().substring(11, 19);
    _consoleLogs.add(LogItem(
      timestamp: time,
      type: type,
      message: message,
      frameId: frameId, // 전달받은 frameId 저장
      objectId: objectId,
    ));
    if (_isConsoleOpen || force) {
      setState(() {});
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isConsoleOpen && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _processCalibration(List<CalibrationPair> data) async {
    try {
      debugPrint("🚀 [ROI_DEBUG] --- ROI 계산 시작 ---");

      // 1. 순방향/역방향 계수 추출
      final srcPoints = data.map((e) => Point(e.src.dx, e.src.dy)).toList();
      final zValues = data.map((e) => e.z).toList(); // 🌟 Z값 리스트 추가
      final dstPoints = data.map((e) => Point(e.dst.dx, e.dst.dy)).toList();

      // 2. 솔버 호출 (zValues 전달)
      var results = PolynomialSolver.solveAll(srcPoints, zValues, dstPoints);

      List<double> fwd = results['forward']!;
      List<double> inv = results['inverse']!;

      // 2. Transformer 업데이트 및 저장
      CoordinateTransformer.setPolynomialCoefficients(fwd);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('polynomial_coeffs', jsonEncode(fwd));

      // 3. ROI 역산 로직
      // double invParallaxRatio = AppConstants.totalSensorHeight / (AppConstants.totalSensorHeight - 110.0);
      double invParallaxRatio = 1.25;
      debugPrint("📊 [ROI_DEBUG] 시차 역산 배율: ${invParallaxRatio.toStringAsFixed(3)}");

      final List<Map<String, dynamic>> roiConfigs = [
        {"id": 1, "name": "Top-Left", "pos": const Offset(0, 0)},
        {"id": 2, "name": "Top-Right", "pos": const Offset(1920, 0)},
        {"id": 3, "name": "Bottom-Left", "pos": const Offset(0, 1080)},
        {"id": 4, "name": "Bottom-Right", "pos": const Offset(1920, 1080)},
        {"id": 5, "name": "Center", "pos": const Offset(960, 540)},
      ];

      List<Map<String, dynamic>> roiPoints = [];

      for (var config in roiConfigs) {
        double ux = config["pos"]!.dx / 1920.0; // UI 정규화
        double uy = config["pos"]!.dy / 1080.0;

        // 역방향 다항식 적용 (결과: 정규화된 센서지면)
        double ngx = inv[0] + inv[1]*ux + inv[2]*uy + inv[3]*ux*uy + inv[4]*ux*ux + inv[5]*uy*uy;
        double ngy = inv[6] + inv[7]*ux + inv[8]*uy + inv[9]*ux*uy + inv[10]*ux*ux + inv[11]*uy*uy;

        // 정규화 해제 (0~1 -> 0~640)
        double gx = ngx * 640.0;
        double gy = ngy * 480.0;

        // 시차 보정 역산 (바닥 -> 센서 윗면)
        double rawX = 320.0 + (gx - 320.0) * invParallaxRatio;
        double rawY = 240.0 + (gy - 240.0) * invParallaxRatio;

        // 최종 클램핑
        double finalX = rawX.clamp(0.0, 640.0);
        double finalY = rawY.clamp(0.0, 480.0);

        debugPrint("📍 [ROI_DEBUG] ${config['name']}: "
            "UI(${config['pos']!.dx.toInt()}, ${config['pos']!.dy.toInt()}) "
            "-> Raw(${finalX.toStringAsFixed(1)}, ${finalY.toStringAsFixed(1)})");

        roiPoints.add({
          "id": config["id"],
          "x": finalX,
          "y": finalY,
        });
      }

      // 4. 전송
      String packet = jsonEncode({
        "event_type": "set_roi",
        "timestamp": DateTime.now().toIso8601String(),
        "roi_points": roiPoints,
      });

      _serverService.sendMessage(packet);
      debugPrint("📤 [ROI_DEBUG] Packet Sent: $packet");

    } catch (e, stack) {
      debugPrint("❌ [ROI_DEBUG] Error: $e");
      debugPrint(stack.toString());
    }
  }

  final Map<String, Timer> _pickupTimers = {};

  void _initializeServer() {
    _serverService = SocketServerService(
        onLog: (msg, {bool force = false}) => _addLog("SYS", msg, force: true),
        onClientConnected: (ip) {
          debugPrint("📡 [IR_CONTROL] 클라이언트 접속 확인($ip)! 0.5초 뒤 IR 설정값 전송");
          // 연결 직후 소켓 버퍼 안정을 위해 아주 짧은 지연 후 전송
          Future.delayed(const Duration(milliseconds: 500), () {
            _sendIrValueToPi(_irValue);
          });
        },
        onOrderReceived: () {
          if (mounted) setState(() => _updateGuidePositions());
        },
        onCalibrationRequested: () {
          if (!mounted) return;
          setState(() {
            CoordinateTransformer.resetMatrix();
            // 센서(RPi)에게도 캘리브레이션 모드임을 알림
            _serverService
                .sendMessage(jsonEncode({"event_type": "cal_restart"}));
            _isCalibrating = true;
          });
        },

        onFineTuneCommand: (subType, value) {
          if (!_isCalibrating) return;

          switch (subType) {
            case 'START':
              _calibKey.currentState?.externalEnterFineTune();
              break;
            case 'SELECT':
              _calibKey.currentState?.externalSelectPoint(value as int);
              break;
            case 'MOVE':
              double dx = (value['dx'] as num).toDouble();
              double dy = (value['dy'] as num).toDouble();
              _calibKey.currentState?.externalAdjust(dx, dy);
              break;
            case 'COMPLETE':
              _calibKey.currentState?.externalComplete();
              _serverService.sendToRole("KDS", jsonEncode({"type": "VALIDATION_MODE"}));
              break;
          }
        },
        onDataReceived: (TofFrame frame) {
          // if (frame.baseZ != null) {
          //   CoordinateTransformer.updateFloorHeight(frame.baseZ!);
          // }
          if (frame.objects.isNotEmpty) {
            var obj = frame.objects.first;
            setState(() {
              _latestRawForCalib = CoordinateTransformer.getFixedParallax(obj.x, obj.y, obj.z);
              _lastFrameObjects = frame.objects;
            });
          }

          // 하지만 컵/손 관리 로직(UI 위젯 생성)은 캘리브레이션 중에는 중단
          if (_isCalibrating) return;
          if (frame.eventType == 'object_tracking') {
            _processHandTracking(frame); // 손(Hand) 전용
          } else {
            _processCupUpdate(frame); // 컵(Cup) 전용
          }
        });
    _serverService.startServer();
  }

  void _processHandTracking(TofFrame frame) {
    // 콘솔 로그 출력 로직
    if (_isConsoleOpen && _showRawData && frame.frameId % 5 == 0) {
      //_addLog("TRK",
      //    "=== [Tracking] Frame: ${frame.frameId} (Count: ${frame.objects.length}) ===",
      //    frameId: frame.frameId);
      for (var obj in frame.objects) {
        //_addLog(
        //  "TRK",
        //  "  > [HandID:${obj.id}] "
        //       "x:${obj.x.toStringAsFixed(0)}, "
        //       "y:${obj.y.toStringAsFixed(0)}, "
        //       "z:${obj.z.toStringAsFixed(0)}, "
        //       "w:${obj.width.toStringAsFixed(0)}, "
        //       "h:${obj.height.toStringAsFixed(0)}",
        //   frameId: frame.frameId,
        //   objectId: obj.id,
        // );
      }
    }

    setState(() {
      _resetHandDetectionTimer();

      if (!_isHandDetected) {
        setState(() => _isHandDetected = true);
      }
      _currentLatestFrameId = frame.frameId; // 현재 프레임 ID 업데이트 (로그 색상 강조용)

      // 손 데이터 변환 및 저장
      hands = frame.objects.map((tof) {
        return DetectedObject(
          id: tof.id,
          orderNo: "HAND",
          position: CoordinateTransformer.transform(tof.x, tof.y, tof.z),
          zValue: tof.z,
          diameter: 0,
          uiWidth: CoordinateTransformer.getUiSize(tof.width, tof.height).width,
          uiHeight: CoordinateTransformer.getUiSize(tof.width, tof.height).height,
          color: Colors.white70,
        );
      }).toList();
    });
  }

  // 1. _processCupUpdate 수정 버전
  void _processCupUpdate(TofFrame frame) {
    final validTofObjects = frame.objects.where((obj) => obj.x > 5 && obj.y > 5).toList();

    if (validTofObjects.isNotEmpty) {
      debugPrint("☕ [RAW_CUP_FRAME] ID:${frame.frameId}");
      for (var obj in validTofObjects) {
        CoordinateTransformer.logTrace("LIVE_CUP_${obj.id}", obj.x, obj.y, obj.z);
        debugPrint("   > [ID:${obj.id.toString().padLeft(3)}] "
            "x:${obj.x.toStringAsFixed(0).padLeft(3)}, "
            "y:${obj.y.toStringAsFixed(0).padLeft(3)}, "
            "z:${obj.z.toStringAsFixed(0).padLeft(4)}, "
            "w:${obj.width.toStringAsFixed(0).padLeft(3)}, "
            "h:${obj.height.toStringAsFixed(0).padLeft(3)}, "
            "r:${(obj.diameter / 2).toStringAsFixed(1).padLeft(4)}");
      }
    }

    List<Map<String, dynamic>> sensorInputs = validTofObjects.map((tof) {
      // 1. 수학적으로 정확한 좌표 구함 (Gain 미적용)
      Offset mathPos = CoordinateTransformer.transform(tof.x, tof.y, tof.z);

      // 2. 🌟 시각적으로 당겨진 좌표 구함 (화면 출력용)
      Offset visualPos = CoordinateTransformer.applyVisualPull(mathPos);
      debugPrint("☕ [TRACE] ID:${tof.id} | Math:(${mathPos.dx.toInt()}, ${mathPos.dy.toInt()}) -> Visual:(${visualPos.dx.toInt()}, ${visualPos.dy.toInt()})");
      Color idBasedColor = _getColorForId(tof.id);
      final orderInfo = OrderManager.getOrAssignOrder(tof.id, visualPos, idBasedColor);

      String displayLabel = "UNKNOWN"; // 기본값
      if (orderInfo != null) {
        displayLabel = _buildComplexLabel(orderInfo);
      }
      return {
        'id': tof.id,
        'pos': visualPos, // 렌더링용 좌표
        'mathPos': mathPos, // 로직용 좌표 (필요시)
        'raw': tof,
        'label': displayLabel,
        'finalColor': orderInfo?['color'] ?? Colors.white54
      };
    }).toList();

    List<DetectedObject> tempList = [];

    // 2. 기존 컵 유지 및 매칭
    for (var existing in objects) {
      int closestIndex = -1;
      double minDistance = 50.0;

      for (int i = 0; i < sensorInputs.length; i++) {
        double dist = (existing.position - (sensorInputs[i]['pos'] as Offset)).distance;
        if (dist < minDistance) {
          minDistance = dist;
          closestIndex = i;
        }
      }

      if (closestIndex != -1) {
        var matched = sensorInputs.removeAt(closestIndex);
        var tof = matched['raw'] as TofObject;
        tempList.add(DetectedObject(
          id: matched['id'],
          orderNo: matched['label'],
          position: matched['pos'],
          zValue: tof.z,
          diameter: CoordinateTransformer.getUiDiameter(tof.diameter),
          uiWidth: CoordinateTransformer.getUiSize(tof.width, tof.height).width,
          uiHeight: CoordinateTransformer.getUiSize(tof.width, tof.height).height,
          color: matched['finalColor'],
        ));
      } else {
        // 컵이 사라질 때 처리
        final removedOrder = OrderManager.releaseId(existing.id);
        exitingObjects.add(existing);

        if (removedOrder != null && removedOrder['orderNo'] != "UNKNOWN") {
          String actualOrderNo = removedOrder['orderNo'].toString();
          String mName = removedOrder['menuName'].toString();

          // 기존 타이머가 있다면 취소 (고스트 재매칭 시 픽업 취소를 위함)
          _pickupTimers[actualOrderNo]?.cancel();

          // 2. 5초(고스트 시간) 대기 타이머 시작
          _pickupTimers[actualOrderNo] = Timer(OrderManager.ghostDuration, () {
            if (!mounted) return;

            bool isStillOnTable = OrderManager.activeMatches.values.any(
                    (match) => match['orderNo'].toString() == actualOrderNo
            );

            // 2. 유령 대기열(ghostMemory)에 이 주문번호를 가진 유령이 하나라도 남아있는가?
            // (방금 사라진 이 컵 말고, 다른 잔이 유령 상태일 수 있음)
            bool hasOtherGhosts = OrderManager.ghostMemory.any(
                    (ghost) => ghost.orderNo == actualOrderNo
            );

            // 테이블 위에도 없고, 다른 유령도 없을 때 (즉, 그 주문의 마지막 잔이 사라졌을 때)
            if (!isStillOnTable && !hasOtherGhosts) {
              _serverService.sendToRole(
                  "KDS",
                  jsonEncode({
                    "type": "PICKUP_COMPLETE",
                    "orderNo": actualOrderNo,
                    "menuName": mName, // 대표 메뉴명
                  })
              );
              debugPrint("📢 [Auto-Pickup] $actualOrderNo번 모든 컵 제거 확인 -> KDS 신호 전송");
            }

            setState(() {
              _pickupTimers.remove(actualOrderNo);
            });
          });
        }
        _videoLayerKey.currentState?.moveVideoToPosition(
            existing.position,
            sensorInputs.map((e) => e['pos'] as Offset).toList()
        );
      }
    }

    // 3. 신규 컵 추가
    for (var nuevo in sensorInputs) {
      var tof = nuevo['raw'] as TofObject;
      tempList.add(DetectedObject(
        id: tof.id,
        orderNo: nuevo['label'],
        position: nuevo['pos'],
        zValue: tof.z,
        diameter: CoordinateTransformer.getUiDiameter(tof.diameter),
        uiWidth: CoordinateTransformer.getUiSize(tof.width, tof.height).width,
        uiHeight: CoordinateTransformer.getUiSize(tof.width, tof.height).height,
        color: nuevo['finalColor'],
      ));
    }

    // 4. 모든 컵의 각도 미리 계산
    final double sw = MediaQuery.of(context).size.width;
    final double sh = MediaQuery.of(context).size.height;
    List<DetectedObject> finalOptimizedList = [];

    for (var obj in tempList) {
      double angle = _getStaticSafeAngle(obj.position, obj.diameter, tempList, sw, sh);
      finalOptimizedList.add(DetectedObject(
        id: obj.id,
        orderNo: obj.orderNo,
        position: obj.position,
        zValue: obj.zValue,
        diameter: obj.diameter,
        uiWidth: obj.uiWidth,
        uiHeight: obj.uiHeight,
        labelAngle: angle,
        color: obj.color,
      ));
    }

    if (mounted) {
      setState(() {
        objects = finalOptimizedList;
        _updateGuidePositions();
        _obstacleNotifier.value = objects.map((e) => e.position).toList();
        _isHandDetected = false;
      });
    }
  }

  double _getStaticSafeAngle(Offset pos, double diameter, List<DetectedObject> others, double sw, double sh) {
    double currentScanAngle = math.pi / 3.0; // 4시 방향 시작
    final double textRadius = (diameter > 0 ? diameter / 2 : 150.0) / 2 + 18.0;

    for (int i = 0; i < 15; i++) {
      double checkX = pos.dx + textRadius * math.cos(currentScanAngle);
      double checkY = pos.dy + textRadius * math.sin(currentScanAngle);

      bool isSafe = (checkX > 40 && checkX < sw - 40 && checkY > 40 && checkY < sh - 40);

      if (isSafe) {
        for (var other in others) {
          // 본인이 아닌 다른 컵과의 충돌 체크
          if (other.position != pos && (Offset(checkX, checkY) - other.position).distance < (other.diameter / 4 + 40)) {
            isSafe = false;
            break;
          }
        }
      }

      if (isSafe) return currentScanAngle;
      currentScanAngle += (math.pi / 24.0); // 빈 공간 찾기
    }
    return math.pi / 3.0; // 실패 시 기본 각도
  }

  void _sendTestCommandToPi() {
    // 1. 임시 데이터 생성
    List<Map<String, dynamic>> dummyObjects = [
      {
        "object_id": 701,
        "position": {"x": 150.5, "y": 150.5},
        "size": {"diameter": 85.0},
        "z_value": 820.0,
        "is_stable": true,
        "velocity": 0.0
      },
      {
        "object_id": 702,
        "position": {"x": 300.0, "y": 400.0},
        "size": {"diameter": 85.0},
        "z_value": 820.0,
        "is_stable": true,
        "velocity": 0.0
      }
    ];

    Map<String, dynamic> txPacket = {
      "event_type": "tx_simulation",
      "timestamp": DateTime.now().toIso8601String(),
      "frame_id": 9999, // 테스트용 프레임 번호
      "objects": dummyObjects
    };

    // 2. JSON 문자열로 변환하여 RPi로 전송
    String jsonString = jsonEncode(txPacket);
    _serverService.sendToRole("TOF_SENSOR", jsonString);

    // 3. 로그 출력
    //_addLog("TX",
    //    "=== Frame: ${txPacket['frame_id']} (Count: ${dummyObjects.length}) ===");

    for (var obj in dummyObjects) {
      // 데이터 추출
      int id = obj['object_id'];
      double x = obj['position']['x'];
      double y = obj['position']['y'];
      double z = obj['z_value'];
      double d = obj['size']['diameter'];

      //_addLog("TX",
      //    "  > [ID:$id] x:${x.toStringAsFixed(0)}, y:${y.toStringAsFixed(0)}, z:${z.toStringAsFixed(0)}, d:${d.toStringAsFixed(0)}");
    }
  }

  @override
  void dispose() {
    _handDetectionTimer?.cancel();
    _serverService.stopServer();
    _adTimer?.cancel();
    _scrollController.dispose();
    _pickupTimers.forEach((key, timer) => timer.cancel());
    _pickupTimers.clear();
    _obstacleNotifier.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 주문 번호별로 그룹핑 (Elastic 효과용)
    Map<String, List<DetectedObject>> groupedObjects = {};
    for (var obj in objects) {
      groupedObjects.putIfAbsent(obj.orderNo, () => []).add(obj);
    }

    // 화면 크기를 가져와서 반응형으로 처리
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;

        return Stack(
          fit: StackFit.expand,
          children: [
            const StaticBackground(),

            //동영상 (Ad)
            FloatingVideoLayer(
              key: _videoLayerKey,
              screenWidth: screenWidth,
              screenHeight: screenHeight,
              obstacleNotifier: _obstacleNotifier,
              onLog: (msg) => debugPrint("[IPS_ANIM] $msg"),
            ),

            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: PickupTablePainter(
                    objects: objects,
                    cupPalette: _idPalette,
                    icons: _iconImages,
                  ),
                ),
              ),
            ),

            RepaintBoundary(
              child: Stack(
                children: [
                  ..._guidePositions.entries.map((entry) {
                    Offset pos = entry.value;
                    String label = _getGuideLabel(entry.key);
                    return AnimatedPositioned(
                      key: ValueKey("guide_${entry.key}"),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeInOut,
                      left: pos.dx - 90,
                      top: pos.dy - 90,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(seconds: 1),
                        builder: (context, val, child) {
                          return Opacity(
                            opacity: val * 0.5, // 이미지 가독성을 위해 0.5 정도 투명도 유지 (조절 가능)
                            child: OrderGuideWidget(
                              label: label,
                              color: Colors.white, // 원하는 색상 지정 가능
                              icons: _iconImages,
                            ),
                          );
                        },
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
            IgnorePointer(
              // 터치 이벤트를 방해하지 않도록 설정
              child: HandDetectionOverlay(visible: _isHandDetected),
            ),

            // (디버깅용) 우측 상단 포트 정보
            Positioned(
              top: 40,
              right: 20,
              child: Text("Port: ${AppConstants.serverPort}",
                  style: const TextStyle(color: Colors.white24)),
            ),

            if (_isConsoleOpen)
              Positioned(
                bottom: 80,
                right: 20,
                width: 600,
                height: 800,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.9),
                    border: Border.all(color: Colors.greenAccent, width: 1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 헤더: 제목 + 스위치 + 닫기
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // 제목
                          const Text("NETWORK MONITOR",
                              style: TextStyle(
                                  color: Colors.greenAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),

                          // 우측 컨트롤 패널 (토글 + 삭제 버튼)
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const RealTimeClock(),
                              ),
                              const SizedBox(width: 12),
                              // 1. Raw Data 토글
                              Text(_showRawData ? "RAW" : "EVENT",
                                  style: TextStyle(
                                      color: _showRawData
                                          ? Colors.greenAccent
                                          : Colors.white54,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                              Transform.scale(
                                scale: 0.7,
                                child: Switch(
                                  value: _showRawData,
                                  activeColor: Colors.greenAccent,
                                  activeTrackColor:
                                      Colors.greenAccent.withOpacity(0.3),
                                  inactiveThumbColor: Colors.grey,
                                  inactiveTrackColor: Colors.white10,
                                  onChanged: (val) {
                                    setState(() {
                                      _showRawData = val;
                                      //_addLog("SYS",
                                      //    "Mode Changed: ${val ? 'Raw Data (All)' : 'Event Only (Diff > $_movementThreshold)'}");
                                    });
                                  },
                                ),
                              ),

                              const SizedBox(width: 8),

                              // 2. 로그 삭제 버튼
                              TextButton.icon(
                                onPressed: () =>
                                    setState(() => _consoleLogs.clear()),
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.white70, size: 18),
                                label: const Text("CLEAR",
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                style: TextButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white24, height: 16),

                      // 로그 리스트 영역
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollController,
                          itemCount: _consoleLogs.length,
                          physics: const ClampingScrollPhysics(),
                          itemBuilder: (context, index) {
                            final log = _consoleLogs[index];

                            // 현재 아이템이 리스트의 마지막(가장 최신)인지 확인
                            bool isLatestLine =
                                index == _consoleLogs.length - 1;

                            // 이 로그가 현재 활성화된(가장 최신) 프레임에 속하는지 확인
                            bool isFromCurrentFrame = log.frameId != null &&
                                log.frameId == _currentLatestFrameId;

                            Color logColor;

                            if (log.objectId != null && isFromCurrentFrame) {
                              // 1. 최신 프레임의 객체 데이터 -> ID별 고유 색상 적용
                              logColor = _getColorForId(log.objectId!);
                            } else if (isLatestLine) {
                              // 2. 객체 데이터는 아니지만 가장 마지막 줄(헤더 등) -> 밝은 흰색
                              logColor = Colors.white;
                            } else if (log.type == "SYS") {
                              // 3. 시스템 로그 -> 어두운 회색
                              logColor = Colors.white54;
                            } else {
                              // 4. 지나간 과거의 프레임 데이터 또는 일반 로그 -> 희미한 색상
                              logColor = Colors.white54;
                            }

                            return Text(
                              // logText,
                              "[${log.timestamp}][${log.type}] ${log.message}",
                              style: TextStyle(
                                color: logColor,
                                fontWeight: isFromCurrentFrame
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                fontSize: 10,
                                fontFamily: 'Courier',
                              ),
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 8),
                      // 하단 버튼: 라즈베리 파이로 데이터 전송 테스트
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white12,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onPressed: _sendTestCommandToPi,
                        icon: const Icon(Icons.send,
                            size: 14, color: Colors.orangeAccent),
                        label: const Text("SEND DATA (Test)",
                            style: TextStyle(fontSize: 11)),
                      )
                    ],
                  ),
                ),
              ),

            // 콘솔 토글 버튼 (우측 하단)
            Positioned(
              bottom: 20,
              right: 20,
              child: FloatingActionButton.small(
                backgroundColor:
                    _isConsoleOpen ? Colors.greenAccent : Colors.grey[800],
                onPressed: () =>
                    setState(() => _isConsoleOpen = !_isConsoleOpen),
                child: Icon(Icons.terminal,
                    color: _isConsoleOpen ? Colors.black : Colors.white),
              ),
            ),
            if (_isCalibrating)
              CalibrationScreen(
                key: _calibKey,
                currentRawPos: _latestRawForCalib,
                currentRawZ: _lastFrameObjects.isNotEmpty ? _lastFrameObjects.first.z : 1000.0,
                onValidationEntered: () {
                  _serverService.sendToRole("KDS", jsonEncode({"type": "VALIDATION_MODE"}));
                },
                onEnterFineTune: () {
                  _serverService.sendToRole("KDS", jsonEncode({"type": "ENTER_FINE_TUNE"}));
                },
                onCalibExit: () {
                  _serverService.sendToRole("KDS", jsonEncode({"type": "CALIB_EXIT"}));
                },

                onCancel: () {
                  _serverService.sendToRole("KDS", jsonEncode({"type": "CALIB_EXIT"}));
                  setState(() => _isCalibrating = false);
                },
                onComplete: (data) {
                  // exit 신호는 위 onCalibExit에서 이미 처리됨
                  setState(() => _isCalibrating = false);
                  _processCalibration(data);
                },
              ),
            // ...OrderManager.ghostMemory.map((ghost) {
            //   return Positioned(
            //     left: ghost.lastPos.dx - 45,
            //     top: ghost.lastPos.dy - 45,
            //     child: Opacity(
            //       opacity: 0.2,
            //       child: Container(
            //         width: 90, height: 90,
            //         decoration: BoxDecoration(
            //           shape: BoxShape.circle,
            //           // BorderStyle.dashed 에러 수정: solid로 변경
            //           border: Border.all(color: Colors.white, width: 2, style: BorderStyle.solid),
            //         ),
            //         child: Center(
            //           child: Text(ghost.orderNo,
            //               style: const TextStyle(color: Colors.white, fontSize: 10)),
            //         ),
            //       ),
            //     ),
            //   );
            // }).toList(),
          ],
        );
      }),
    );
  }

  final Map<String, Offset> _guidePositions = {};
  final Random _random = Random();

// 빈 공간을 찾는 함수
  Offset _findSafePosition(List<DetectedObject> currentCups) {
    int attempts = 0;
    const double minDistance = 250.0; // 컵과 가이드 사이의 최소 안전 거리

    while (attempts < 50) {
      double x = _random.nextDouble() * (1920 - 400) + 200; // 가로 범위 제한
      double y = _random.nextDouble() * (1080 - 400) + 200; // 세로 범위 제한
      Offset candidate = Offset(x, y);

      // 1. 현재 테이블 위 컵들과의 거리 체크
      bool isFarFromCups = currentCups
          .every((cup) => (cup.position - candidate).distance > minDistance);

      // 2. 다른 가이드 서클들과의 거리 체크
      bool isFarFromGuides = _guidePositions.values
          .every((pos) => (pos - candidate).distance > minDistance);

      if (isFarFromCups && isFarFromGuides) return candidate;
      attempts++;
    }
    return const Offset(960, 540); // 실패 시 중앙 반환
  }

// 주문 대기열 상태와 가이드 좌표 싱크
  void _updateGuidePositions() {
    final pendingOrders = OrderManager.waitingQueue;
    final currentOrderIds = pendingOrders.map((o) => o['orderNo']!).toSet();

    // 1. 사라진 주문(매칭 완료된 주문)의 가이드 좌표 제거
    _guidePositions
        .removeWhere((orderNo, _) => !currentOrderIds.contains(orderNo));

    // 2. 새로 들어온 주문에 대해서만 새 좌표 할당
    for (var order in pendingOrders) {
      String no = order['orderNo']!;
      if (!_guidePositions.containsKey(no)) {
        _guidePositions[no] = _findSafePosition(objects);
      }
    }
  }
}

// ==================== [Components: Layer 2 - Floating Video] ====================
// 컵을 피해다니는 비디오 플레이어
class FloatingVideoLayer extends StatefulWidget {
  final double screenWidth;
  final double screenHeight;
  final ValueNotifier<List<Offset>> obstacleNotifier;
  final Function(String)? onLog;

  const FloatingVideoLayer({
    super.key,
    required this.screenWidth,
    required this.screenHeight,
    required this.obstacleNotifier,
    this.onLog,
  });

  @override
  State<FloatingVideoLayer> createState() => FloatingVideoLayerState();
}

class FloatingVideoLayerState extends State<FloatingVideoLayer> {
  late final Player _player;
  late final VideoController _controller;

  Offset _videoPos = Offset.zero;
  double _videoSize = 300.0;
  final Random _random = Random();

  final double minVideoSize = 150.0;
  final double maxVideoSize = 600.0;

  bool _isFollowingPickup = false;
  Timer? _returnTimer;
  bool _isVisible = true;

  static const Duration moveDuration = Duration(milliseconds: 2500);
  static const Duration sizeDuration = Duration(milliseconds: 1500);
  static const Curve animationCurve = Curves.easeInOutQuart;

  @override
  void initState() {
    super.initState();

    _player = Player();
    _controller = VideoController(
      _player,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // 1초 대기 (T982 보드에서 네이티브 Surface가 안정화되는 최소 시간)
      await Future.delayed(const Duration(milliseconds: 1000));

      final playerPlatform = _player.platform;
      if (playerPlatform is NativePlayer) {
        try {
          await playerPlatform.setProperty('hwdec', 'mediacodec');
          await playerPlatform.setProperty('video-sync', 'display-desync');
          await playerPlatform.setProperty('framedrop', 'vo');
          await playerPlatform.setProperty('demuxer-max-bytes', '1M');
          await playerPlatform.setProperty('cache', 'no');

          debugPrint("🚀 [IPS_DEBUG] T982 Video Buffer Optimized");
        } catch (e) {
          debugPrint("⚠️ [IPS_ERROR] Tuning failed: $e");
        }
      }

      // 비디오를 열 때 '재생'은 하지 않고 준비만 시킴
      await _player.open(Media('asset://assets/videos/video_stbs2.mp4'),
          play: false);
      await _player.setPlaylistMode(PlaylistMode.loop);
      await _player.setVolume(0);

      // 마지막으로 짧게 대기 후 재생 시작
      await Future.delayed(const Duration(milliseconds: 200));
      await _player.play();
      await _player.setRate(1.0);

      findNextSafePosition();
    });

    widget.obstacleNotifier.addListener(_handleObstacles);
  }

  void _handleObstacles() {
    if (!mounted) return;

    // 고정 모드일 때는 장애물을 만나도 위치를 옮기지 않고 '크기만' 조절합니다.
    if (_isFollowingPickup) {
      _adjustSizeOnly(widget.obstacleNotifier.value);
    } else {
      _adjustSizeToSurroundings(widget.obstacleNotifier.value);
    }
  }

  void _adjustSizeOnly(List<Offset> obstacles) {
    Offset currentCenter = _videoPos + Offset(_videoSize / 2, _videoSize / 2);
    double rawSize = _calculateMaxAvailableSize(currentCenter, obstacles);

    // 만약 주변 컵 때문에 영상이 너무 작아지면(minVideoSize 미만) 강제로 고정 해제하고 도망
    if (rawSize < minVideoSize) {
      _isFollowingPickup = false;
      findNextSafePosition();
      return;
    }

    double newSize = rawSize.clamp(minVideoSize, maxVideoSize);
    if ((newSize - _videoSize).abs() < 5.0) return;

    setState(() {
      _videoSize = newSize;
      _videoPos = currentCenter - Offset(newSize / 2, newSize / 2);
    });
  }

  // 영상 길이
  Duration getVideoDuration() {
    Duration duration = _player.state.duration;
    return (duration == Duration.zero) ? const Duration(seconds: 15) : duration;
  }

  Offset _getStrictSafeCenter(Offset targetCenter, double targetSize) {
    final double radius = targetSize / 2;
    const double margin = 10.0; // 최소 10px의 물리적 여유

    double minX = radius + margin;
    double maxX = widget.screenWidth - radius - margin;
    double minY = radius + margin;
    double maxY = widget.screenHeight - radius - margin;

    return Offset(
      targetCenter.dx.clamp(minX, maxX),
      targetCenter.dy.clamp(minY, maxY),
    );
  }

  // 컵이 사라진 위치로 이동
  Future<void> moveVideoToPosition(
      Offset pickupPos, List<Offset> obstacles) async {
    if (!mounted || _isFollowingPickup) return;

    _isFollowingPickup = true; // 고정 모드 활성화
    _returnTimer?.cancel();

    Offset optimizedPickupPos = pickupPos;
    double bestPickupSize = _calculateMaxAvailableSize(pickupPos, obstacles);

    for (int i = 0; i < 5; i++) {
      double angle = i * (2 * math.pi / 5);
      Offset offsetCandidate = pickupPos +
          Offset(math.cos(angle) * 80, math.sin(angle) * 80); // 80px 반경 조사
      double candidateSize =
          _calculateMaxAvailableSize(offsetCandidate, obstacles);

      if (candidateSize > bestPickupSize) {
        bestPickupSize = candidateSize;
        optimizedPickupPos = offsetCandidate;
      }
    }

    double rawTargetSize = bestPickupSize.clamp(minVideoSize, maxVideoSize);
    Offset finalTargetCenter =
        _getStrictSafeCenter(optimizedPickupPos, rawTargetSize);
    double finalTargetSize =
        _calculateMaxAvailableSize(finalTargetCenter, obstacles)
            .clamp(minVideoSize, maxVideoSize);
    Offset finalLeftTopPos =
        finalTargetCenter - Offset(finalTargetSize / 2, finalTargetSize / 2);

    setState(() {
      _videoPos = finalLeftTopPos;
      _videoSize = finalTargetSize;
    });

    _returnTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        _isFollowingPickup = false;
        findNextSafePosition();
      }
    });
  }

  // 현재 위치 유지하면서 크기만 조절
  void _adjustSizeToSurroundings(List<Offset> obstacles) {
    if (!mounted) return;
    Offset currentCenter = _videoPos + Offset(_videoSize / 2, _videoSize / 2);
    double rawSize = _calculateMaxAvailableSize(currentCenter, obstacles);

    if (rawSize < minVideoSize) {
      findNextSafePosition();
      return;
    }

    double newSize = rawSize.clamp(minVideoSize, maxVideoSize);
    if ((newSize - _videoSize).abs() < 5.0) return;

    setState(() {
      _videoSize = newSize;
      _videoPos = currentCenter - Offset(newSize / 2, newSize / 2);
    });
  }

  // 특정 위치에서 가능한 최대 크기 계산
  double _calculateMaxAvailableSize(Offset center, List<Offset> obstacles) {
    // 1. 벽까지의 거리
    double distToLeft = center.dx;
    double distToRight = widget.screenWidth - center.dx;
    double distToTop = center.dy;
    double distToBottom = widget.screenHeight - center.dy;
    double minToWall =
        [distToLeft, distToRight, distToTop, distToBottom].reduce(min);

    // 2. 장애물까지의 거리
    double minToObstacle = double.infinity;
    const double obstacleRadius = 70.0;

    if (obstacles.isNotEmpty) {
      for (var obstacle in obstacles) {
        double dist = (obstacle - center).distance - obstacleRadius;
        if (dist < minToObstacle) minToObstacle = dist;
      }
    }

    // 3. 75% 적용
    double maxRadius = min(minToWall, minToObstacle);
    double calculatedSize = (maxRadius * 2) * 0.9;

    return calculatedSize;
  }

  // 빈 공간 찾기 (초기 실행 or 영상 종료 후)
  void findNextSafePosition() {
    if (!mounted) return;
    final List<Offset> obstacles = widget.obstacleNotifier.value;
    // 테이블 위에 아무것도 없으면? -> 정중앙
    if (obstacles.isEmpty) {
      _updateVisibility(true);
      Offset centerScreen = Offset(widget.screenWidth / 2, widget.screenHeight / 2);
      double finalSize = _calculateMaxAvailableSize(centerScreen, []).clamp(minVideoSize, maxVideoSize);
      setState(() {
        _videoPos = centerScreen - Offset(finalSize / 2, finalSize / 2);
        _videoSize = finalSize;
      });
      return;
    }

    Offset bestCenter = Offset.zero;
    double bestSize = 0;
    const int samplingCount = 50; // 20군데를 찔러보고 가장 좋은 곳 선택

    for (int i = 0; i < samplingCount; i++) {
      // 랜덤 후보지 생성
      double randX = _random.nextDouble() * (widget.screenWidth - 400) + 200;
      double randY = _random.nextDouble() * (widget.screenHeight - 400) + 200;
      Offset candidateCenter = Offset(randX, randY);

      // 해당 위치에서 가능한 최대 크기 계산
      double currentSize =
          _calculateMaxAvailableSize(candidateCenter, obstacles);

      // 기존에 찾은 곳보다 더 큰 공간이면 업데이트
      if (currentSize > bestSize) {
        bestSize = currentSize;
        bestCenter = candidateCenter;
      }
    }

    // 최종 선택된 최적지로 이동
    if (bestSize < minVideoSize) {
      _updateVisibility(false); // 공간 없으면 숨김
    } else {
      _updateVisibility(true);  // 공간 있으면 표시
      double finalSize = bestSize.clamp(minVideoSize, maxVideoSize);
      setState(() {
        _videoSize = finalSize;
        _videoPos = _getStrictSafeCenter(bestCenter, finalSize) - Offset(finalSize / 2, finalSize / 2);
      });
    }
  }

  void _updateVisibility(bool visible) {
    if (_isVisible == visible) return;
    setState(() {
      _isVisible = visible;
    });
    // 리소스 절약을 위해 숨겨질 때 정지, 보일 때 재생
    if (visible) {
      _player.play();
    } else {
      _player.pause();
    }
  }

  @override
  void dispose() {
    widget.obstacleNotifier.removeListener(_handleObstacles);
    _player.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(FloatingVideoLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.obstacleNotifier != oldWidget.obstacleNotifier) {
      oldWidget.obstacleNotifier.removeListener(_handleObstacles);
      widget.obstacleNotifier.addListener(_handleObstacles);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: moveDuration,
      curve: animationCurve,
      left: _videoPos.dx,
      top: _videoPos.dy,
      child: AnimatedOpacity( // 투명도 애니메이션 추가
        duration: const Duration(milliseconds: 500),
        opacity: _isVisible ? 1.0 : 0.0,
        child: RepaintBoundary( // 독립적 렌더링 레이어 보장
          child: AnimatedContainer(
            duration: sizeDuration,
            curve: animationCurve,
            width: _videoSize,
            height: _videoSize,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
            clipBehavior: Clip.hardEdge,
            child: Video(controller: _controller, fit: BoxFit.cover, controls: NoVideoControls),
          ),
        ),
      ),
    );
  }
}

// ==================== [Components: Layer 3 - Group Connector] ====================
class GroupConnectorPainter extends CustomPainter {
  final List<DetectedObject> objects;

  GroupConnectorPainter({required this.objects});

  @override
  void paint(Canvas canvas, Size size) {
    if (objects.length < 2) return;

    final paint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.15) // 그룹 색상
      ..style = PaintingStyle.stroke
      ..strokeWidth = 60.0
      ..strokeCap = StrokeCap.round;
      // ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30); // 빛 번짐 효과

    final path = Path();
    for (int i = 0; i < objects.length; i++) {
      for (int j = i + 1; j < objects.length; j++) {
        path.moveTo(objects[i].position.dx, objects[i].position.dy);
        // 컵과 컵 사이를 잇는 부드러운 곡선
        path.quadraticBezierTo(
            (objects[i].position.dx + objects[j].position.dx) / 2,
            (objects[i].position.dy + objects[j].position.dy) / 2 + 40,
            objects[j].position.dx,
            objects[j].position.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Grid System Component (새로 추가됨)
class GridPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint linePaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final Paint nodePaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.fill;

    const double step = 100.0; // 100픽셀 단위

    // 세로선 그리기
    for (double x = 0; x <= size.width; x += step) {
      _drawDashedLine(canvas, linePaint, Offset(x, 0), Offset(x, size.height));
    }

    // 가로선 그리기
    for (double y = 0; y <= size.height; y += step) {
      _drawDashedLine(canvas, linePaint, Offset(0, y), Offset(size.width, y));
    }

    // 교차점(Node) 그리기
    for (double x = 0; x <= size.width; x += step) {
      for (double y = 0; y <= size.height; y += step) {
        // 교차점에 작은 원
        canvas.drawCircle(Offset(x, y), 2.0, nodePaint);

        TextSpan span = TextSpan(
            style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 8),
            text: "(${x.toInt()},${y.toInt()})");
        TextPainter tp =
            TextPainter(text: span, textDirection: TextDirection.ltr);
        tp.layout();
        tp.paint(canvas, Offset(x + 4, y + 4));
      }
    }
  }

  // 점선 그리기 헬퍼 함수
  void _drawDashedLine(Canvas canvas, Paint paint, Offset p1, Offset p2) {
    const int dashWidth = 4;
    const int dashSpace = 4;
    double startX = p1.dx;
    double startY = p1.dy;

    // 수직선인 경우
    if (p1.dx == p2.dx) {
      while (startY < p2.dy) {
        canvas.drawLine(
            Offset(startX, startY), Offset(startX, startY + dashWidth), paint);
        startY += dashWidth + dashSpace;
      }
    }
    // 수평선인 경우
    else {
      while (startX < p2.dx) {
        canvas.drawLine(
            Offset(startX, startY), Offset(startX + dashWidth, startY), paint);
        startX += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class StaticBackground extends StatelessWidget {
  const StaticBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1A)],
              ),
            ),
            child: const Center(
              child: Text(
                "AIO PICKUP TABLE",
                style: TextStyle(
                  color: Colors.white10,
                  fontSize: 80,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          CustomPaint(
            size: Size.infinite,
            painter: GridPatternPainter(),
          ),
        ],
      ),
    );
  }
}

class RealTimeClock extends StatefulWidget {
  const RealTimeClock({super.key});
  @override
  State<RealTimeClock> createState() => _RealTimeClockState();
}

class _RealTimeClockState extends State<RealTimeClock> {
  late Timer _timer;
  String _timeStr = "";

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now();
      setState(() {
        _timeStr =
            "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(_timeStr,
        style: const TextStyle(
            color: Colors.yellowAccent,
            fontSize: 12,
            fontFamily: 'Courier',
            fontWeight: FontWeight.bold));
  }
}

class PickupTablePainter extends CustomPainter {
  final List<DetectedObject> objects;
  final List<Color> cupPalette;
  final Map<String, ui.Image> icons;

  PickupTablePainter({required this.objects, required this.cupPalette, required this.icons});

  @override
  void paint(Canvas canvas, Size size) {
    for (var obj in objects) {
      final color = obj.color;

      // 1. 컵 원 그리기용 Paint 설정
      final circlePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      final double radius = (obj.diameter > 0 ? obj.diameter / 2 : 100.0) / 2;

      // 2. 컵 원형 테두리 그리기
      canvas.drawCircle(obj.position, radius, circlePaint);

      // 3. 주문 번호(이름) 텍스트 그리기
      _drawTextLabel(canvas, obj, color, radius);
    }
  }

  void _drawTextLabel(Canvas canvas, DetectedObject obj, Color color, double radius) {
    final String text = obj.orderNo;
    final double textRadius = radius + 15.0;

    // 1. 그릴 요소들을 미리 준비 (이미지인지 텍스트인지 구분)
    final List<Map<String, dynamic>> elements = [];
    double totalWidth = 0;

    for (var char in text.characters) {
      ui.Image? icon = icons[char]; // ✨ 미리 로드된 PNG 아이콘 확인

      if (icon != null) {
        // [아이콘인 경우]
        const double iconSize = 24.0;
        elements.add({
          'type': 'icon',
          'data': icon,
          'width': iconSize,
        });
        totalWidth += iconSize;
      } else {
        // [일반 글자/구분선인 경우]
        Color charColor = (char == '|') ? Colors.white38 : color;
        final tp = TextPainter(
          text: TextSpan(
            text: char,
            style: TextStyle(
              color: charColor,
              fontSize: 20,
              fontFamily: 'CenturyGothic',
              fontWeight: FontWeight.w400,
              letterSpacing: 1.2,
              fontFamilyFallback: ['Noto Color Emoji'],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        elements.add({
          'type': 'text',
          'data': tp,
          'width': tp.width,
        });
        totalWidth += tp.width;
      }
    }

    // 2. 중앙 정렬을 위한 각도 계산
    double totalAngle = totalWidth / textRadius;
    double currentAngle = obj.labelAngle + (totalAngle / 2);

    // 3. 루프를 돌며 실제 그리기
    for (var element in elements) {
      final double elementWidth = element['width'] as double;
      final double charAngle = elementWidth / textRadius;
      final double drawAngle = currentAngle - (charAngle / 2);

      final double x = obj.position.dx + textRadius * math.cos(drawAngle);
      final double y = obj.position.dy + textRadius * math.sin(drawAngle);

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(drawAngle - math.pi / 2);

      if (element['type'] == 'icon') {
        // ✨ PNG 아이콘 그리기
        final ui.Image icon = element['data'] as ui.Image;
        const double iconSize = 24.0;
        canvas.drawImageRect(
          icon,
          Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
          Rect.fromLTWH(-iconSize / 2, -iconSize / 2, iconSize, iconSize),
          Paint()..filterQuality = ui.FilterQuality.high,
        );
      } else {
        // ✨ 텍스트(닉네임/구분선) 그리기
        final TextPainter tp = element['data'] as TextPainter;
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      }

      canvas.restore();
      currentAngle -= charAngle;
    }
  }

  @override
  bool shouldRepaint(PickupTablePainter oldDelegate) {
    // 객체 리스트가 바뀌었을 때만 다시 그리도록 최적화
    return oldDelegate.objects != objects;
  }
}