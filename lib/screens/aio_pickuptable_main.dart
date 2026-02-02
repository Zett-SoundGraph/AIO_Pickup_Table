  import 'dart:async';
import 'dart:convert';
import 'dart:io';
  import 'dart:math';
import 'dart:math' as math;
  import 'package:aio_pickup_table/components/guide_circle.dart';
import 'package:flutter/material.dart';
  import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ml_linalg/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
  
  import '../components/animation_kit.dart';
import '../components/arc_text_painter.dart';
import '../services/coordinate_transformer.dart';
import '../services/homography_solver.dart';
import '../services/order_manager.dart';
import '../services/socket_server_service.dart';
  import '../models/pickup_data.dart';
  import '../config/app_constants.dart';
import 'calibration_screen.dart';

  class LogItem {
    final String timestamp; // 시간
    final String type;      // RX, TX, SYS, MOVE 등
    final String message;   // 로그 내용
    final int? frameId;     // 프레임 ID (색상 구분용, null이면 시스템 로그)
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
    final double zValue;   // 높이
    final double diameter; // 지름
    final double uiWidth;
    final double uiHeight;
  
    DetectedObject({
      required this.id,
      required this.orderNo,
      required this.position,
      required this.zValue,
      required this.diameter,
      required this.uiWidth,
      required this.uiHeight,
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
  
    // 화면 배율 (테이블 크기에 맞춰 조절)
    final double scaleRatio = 3.17;
    final double sizeCorrection = 0.75;

    // 로그 제어용 변수
    bool _showRawData = true;
    List<TofObject> _lastFrameObjects = [];
    final double _movementThreshold = 2.0;

    // 시계 표시용 변수 및 타이머
    String _currentTimeStr = "00:00:00";
    Timer? _clockTimer;

    final List<Color> _idPalette = List.generate(100, (index) {
      double hue = (index * 137.508) % 360;

      double saturation = (index % 2 == 0) ? 0.9 : 0.5;

      double value = 1.0 - ((index % 3) * 0.2);

      return HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
    });

    int? _currentLatestFrameId;

// ID를 기반으로 색상을 가져오는 헬퍼 함수
    Color _getColorForId(int id) {
      if (id < 0) return Colors.white54; // 시스템 로그용
      return _idPalette[id % _idPalette.length];
    }
    
    @override
    void initState() {
      super.initState();
      _loadSavedMatrix();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _initializeServer();

      // 테스트용 WebSocket Server IP, Port
      _logCurrentServerIp();
      _startClock();
    }

    Future<void> _loadSavedMatrix() async {
      final prefs = await SharedPreferences.getInstance();
      final String? matrixJson = prefs.getString('homography_matrix');

      if (matrixJson != null) {
        try {
          List<double> matrix = List<double>.from(jsonDecode(matrixJson));
          CoordinateTransformer.setHomographyMatrix(matrix);
          _addLog("SYS", "✅ 이전 캘리브레이션 설정을 불러왔습니다.");
        } catch (e) {
          _addLog("ERR", "설정 로드 실패: $e");
        }
      }
    }

    // 실시간 시계 타이머
    void _startClock() {
      _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          final now = DateTime.now();
          setState(() {
            _currentTimeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
          });
        }
      });
    }

    bool _hasSignificantChange(List<TofObject> newObjs, List<TofObject> oldObjs) {
      // 1. 개수가 다르면 무조건 변화 (진입/퇴장)
      if (newObjs.length != oldObjs.length) return true;

      // 2. 개수가 같다면, 위치 이동 체크
      for (var newObj in newObjs) {
        // ID가 같은 이전 객체 찾기
        var oldObj = oldObjs.firstWhere(
              (o) => o.id == newObj.id,
          orElse: () => TofObject(id: -1, x: 0, y: 0, z: 0, diameter: 0, width: 0, height: 0, isStable: false),
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

          _addLog("SYS", "========================================");
          _addLog("SYS", " WebSocket Server Running ");
          _addLog("SYS", " IP Address : ${addr.address} ");
          _addLog("SYS", " Port       : ${AppConstants.serverPort} ");
          _addLog("SYS", "========================================");

          return;
        }
      } catch (e) {
        _addLog("SYS", "IP 주소 조회 실패: $e");
      }
    }

    bool _isConsoleOpen = false;
    //bool _showRawData = false;
    //final List<String> _consoleLogs = [];
    final List<LogItem> _consoleLogs = [];
    final ScrollController _scrollController = ScrollController();

    // final GlobalKey<FloatingVideoLayerState> _videoLayerKey = GlobalKey<FloatingVideoLayerState>();
    // bool _isAdPlaying = false;
    // Timer? _adTimer;


    void _addLog(String type, String message, {int? frameId, int? objectId}) {
      if (!mounted) return;

        if (_consoleLogs.length > 100) _consoleLogs.removeAt(0); // 최대 100줄 유지

        String time = DateTime.now().toIso8601String().substring(11, 19);
        _consoleLogs.add(LogItem(
          timestamp: time,
          type: type,
          message: message,
          frameId: frameId, // 전달받은 frameId 저장
          objectId: objectId,
        ));
        if (_isConsoleOpen) {
          setState(() {});
        }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isConsoleOpen && _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }

    void _processCalibration(List<CalibrationPair> data) async {
      _addLog("SYS", "🎯 9-Point Calibration Data Collected");

      List<Point<double>> srcPoints = data.map((e) => Point(e.src.dx, e.src.dy)).toList();
      List<Point<double>> dstPoints = data.map((e) => Point(e.dst.dx, e.dst.dy)).toList();

      try {
        // 1. 호모그래피 행렬 계산 (한 번만 수행)
        final Matrix hMatrix = HomographySolver.solve(srcPoints, dstPoints);

        String matrixLog = "";
        for(int i=0; i<3; i++) {
          matrixLog += "[${hMatrix[i][0].toStringAsFixed(4)}, ${hMatrix[i][1].toStringAsFixed(4)}, ${hMatrix[i][2].toStringAsFixed(4)}] ";
        }
        debugPrint("📊 생성된 행렬: $matrixLog");

        // 2. 행렬 값 리스트화 및 적용
        List<double> matrixValues = [
          hMatrix[0][0], hMatrix[0][1], hMatrix[0][2],
          hMatrix[1][0], hMatrix[1][1], hMatrix[1][2],
          hMatrix[2][0], hMatrix[2][1], hMatrix[2][2],
        ];
        CoordinateTransformer.setHomographyMatrix(matrixValues);

        // 3. 로컬 저장소에 저장
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('homography_matrix', jsonEncode(matrixValues));
        _addLog("SYS", "🎯 캘리브레이션 완료 및 저장 성공!");

        // 4. ROI 역산 및 라즈베리파이 전송
        final Matrix invH = hMatrix.inverse(); // 역행렬 계산
        final List<Map<String, dynamic>> roiConfigs = [
          {"id": 1, "name": "Top-Left", "pos": const Offset(100, 100)},
          {"id": 2, "name": "Top-Right", "pos": const Offset(1770, 100)},
          {"id": 3, "name": "Bottom-Left", "pos": const Offset(100, 1030)},
          {"id": 4, "name": "Bottom-Right", "pos": const Offset(1770, 1030)},
          {"id": 5, "name": "Center", "pos": const Offset(935, 565)},
        ];

        List<Map<String, dynamic>> roiPoints = [];
        _addLog("SYS", "📡 ROI Mapping (UI -> Camera Raw)");

        for (var config in roiConfigs) {
          final int id = config["id"];
          final String name = config["name"];
          final Offset uiPos = config["pos"];

          // 호모그래피 역행렬을 이용한 좌표 변환 공식
          // x' = (h11*x + h12*y + h13) / (h31*x + h32*y + h33)
          double den = invH[2][0] * uiPos.dx + invH[2][1] * uiPos.dy + invH[2][2];
          double rx = (invH[0][0] * uiPos.dx + invH[0][1] * uiPos.dy + invH[0][2]) / den;
          double ry = (invH[1][0] * uiPos.dx + invH[1][1] * uiPos.dy + invH[1][2]) / den;

          _addLog("ROI", "ID:$id ($name): Raw(${rx.toStringAsFixed(1)}, ${ry.toStringAsFixed(1)})");

          // 전송용 리스트에 ID와 좌표 추가
          roiPoints.add({
            "id": id,
            "x": rx,
            "y": ry,
          });
        }

        _serverService.sendMessage(jsonEncode({
          "event_type": "set_roi",
          "timestamp": DateTime.now().toIso8601String(),
          "roi_points": roiPoints,
        }));
        // _serverService.sendMessage(jsonEncode({
        //   "event_type": "set_roi",
        //   "timestamp": DateTime.now().toIso8601String(),
        //   "roi_points": roiPoints.map((p) => {
        //     "id": p['id'],
        //     // ★ 소수점 4자리까지만 반올림하여 전송 (데이터 가독성 및 안정성 향상)
        //     "x": double.parse(p['x'].toStringAsFixed(4)),
        //     "y": double.parse(p['y'].toStringAsFixed(4)),
        //   }).toList(),
        // }));
        _addLog("SYS", "📤 ROI Packet Sent to Raspberry Pi");

      } catch (e) {
        _addLog("ERR", "Calibration/ROI Error: $e");
      }
    }
    final Map<String, Timer> _pickupTimers = {};
    void _initializeServer() {
      _serverService = SocketServerService(
          onLog: (msg) => _addLog("SYS", msg),
          onOrderReceived: () {
            if (mounted) setState(() => _updateGuidePositions());
          },
          onDataReceived: (TofFrame frame) {
            // 1. [입구 컷] 0,0 데이터 및 너무 작은 노이즈(지름 40mm 이하)는 로직 연산에서 제외
            // 로그에는 frame.objects를 써서 다 보여주되, 실제 UI 계산은 validTofObjects만 씁니다.
            final validTofObjects = frame.objects.where((obj) =>
            obj.x != 0 && obj.y != 0
            ).toList();

            if (frame.baseZ != null) {
              CoordinateTransformer.updateFloorHeight(frame.baseZ!);
            }

            // 단일 setState로 통합 (초당 렌더링 부하 감소)
            setState(() {
              // [로그 1] 캘리브레이션용 좌표 (전체 데이터 기준)
              if (frame.objects.isNotEmpty) {
                var obj = frame.objects.first;
                _latestRawForCalib = CoordinateTransformer.getParallaxCorrectedOffset(obj.x, obj.y, obj.z);
              } else {
                _latestRawForCalib = null;
              }

              // [로그 2] 화면 콘솔 로그 (기존 로직 및 색상 유지)
              bool isChanged = _hasSignificantChange(frame.objects, _lastFrameObjects);
              if (_showRawData || isChanged) {
                String tag = (!_showRawData && isChanged) ? "MOVE" : "RX";
                _addLog(tag, "=== Frame: ${frame.frameId} (Count: ${frame.objects.length}, BaseZ: ${frame.baseZ?.toStringAsFixed(1)}) ===", frameId: frame.frameId);
                for (var obj in frame.objects) {
                  _addLog(
                      tag,
                      "  > [ID:${obj.id}] "
                          "x:${obj.x.toStringAsFixed(0)}, "
                          "y:${obj.y.toStringAsFixed(0)}, "
                          "z:${obj.z.toStringAsFixed(0)}, "
                          "w:${obj.width.toStringAsFixed(0)}, "
                          "h:${obj.height.toStringAsFixed(0)}, "
                          "r:${(obj.diameter / 2).toStringAsFixed(1)}",
                      frameId: frame.frameId,
                      objectId: obj.id
                  );
                }
              }
              _lastFrameObjects = frame.objects;
              _currentLatestFrameId = frame.frameId;

              // 2. 실제 UI 변환 (필터링된 데이터만 사용)
              List<Map<String, dynamic>> sensorInputs = validTofObjects.map((tof) {
                Offset calibratedPos = CoordinateTransformer.transform(tof.x, tof.y, tof.z);

                // 터미널 디버그 로그 (유지)
                debugPrint("[CALIB] ID:${tof.id} | Raw(${tof.x.toInt()}, ${tof.y.toInt()}) -> UI(${calibratedPos.dx.toInt()}, ${calibratedPos.dy.toInt()})");

                return {
                  'id': tof.id,
                  'pos': calibratedPos,
                  'raw': tof
                };
              }).toList();

              List<DetectedObject> nextObjects = [];

              // 3. 기존 컵 유지 및 매칭 (기존 로직 유지)
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

                  _pickupTimers[existing.orderNo]?.cancel();
                  _pickupTimers.remove(existing.orderNo);

                  OrderManager.getOrAssignOrder(matched['id'], matched['pos']);

                  nextObjects.add(DetectedObject(
                    id: matched['id'], orderNo: existing.orderNo, position: matched['pos'],
                    zValue: tof.z, diameter: CoordinateTransformer.getUiDiameter(tof.diameter),
                    uiWidth: CoordinateTransformer.getUiSize(tof.width, tof.height).width,
                    uiHeight: CoordinateTransformer.getUiSize(tof.width, tof.height).height,
                  ));
                } else {
                  // 픽업 완료 처리
                  final removedOrder = OrderManager.releaseId(existing.id);
                  if (removedOrder != null && removedOrder['orderNo'] != "UNKNOWN") {

                    String oNo = removedOrder['orderNo'].toString();
                    String mName = removedOrder['menuName'].toString();

                    _pickupTimers[oNo]?.cancel();

                    // 고스트 지속시간(2초)보다 100ms 정도 일찍 체크하여
                    // cleanup에 의해 삭제되기 직전에 KDS 신호를 보냅니다.
                    _pickupTimers[oNo] = Timer(OrderManager.ghostDuration, () {
                      if (!mounted) return;

                      _serverService.sendToRole("KDS", jsonEncode({
                        "type": "PICKUP_COMPLETE",
                        "orderNo": oNo,
                        "menuName": mName,
                      }));

                      _addLog("TX", "📤 KDS로 픽업 완료 신호 전송: No.$oNo");

                      setState(() {
                        _pickupTimers.remove(oNo);
                      });
                    });
                  }
                  exitingObjects.add(existing);
                }
              }

              // 4. 신규 컵 추가
              for (var nuevo in sensorInputs) {
                var tof = nuevo['raw'] as TofObject;

                // [isStable 대응 주석] 나중에 ToF 측에서 값을 보내주면 아래 if문을 활성화하세요.
                // if (tof.isStable) { ... }

                final orderInfo = OrderManager.getOrAssignOrder(tof.id, nuevo['pos']);

                String oNo = "UNKNOWN"; // 기본값
                if (orderInfo != null) {
                  oNo = orderInfo['orderNo'].toString();
                  // 주문 번호가 있다면 타이머 취소
                  _pickupTimers[oNo]?.cancel();
                  _pickupTimers.remove(oNo);
                }

                // orderInfo가 null이더라도(UNKNOWN이더라도) 리스트에는 추가하여 원을 그려줌
                nextObjects.add(DetectedObject(
                  id: tof.id,
                  orderNo: oNo,
                  position: nuevo['pos'],
                  zValue: tof.z,
                  diameter: CoordinateTransformer.getUiDiameter(tof.diameter),
                  uiWidth: CoordinateTransformer.getUiSize(tof.width, tof.height).width,
                  uiHeight: CoordinateTransformer.getUiSize(tof.width, tof.height).height,
                ));
              }

              objects = nextObjects;
              _updateGuidePositions();
            });
          }
      );
      _serverService.startServer();
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
      _addLog("TX", "=== Frame: ${txPacket['frame_id']} (Count: ${dummyObjects.length}) ===");

      for (var obj in dummyObjects) {
        // 데이터 추출
        int id = obj['object_id'];
        double x = obj['position']['x'];
        double y = obj['position']['y'];
        double z = obj['z_value'];
        double d = obj['size']['diameter'];

        _addLog(
            "TX",
            "  > [ID:$id] x:${x.toStringAsFixed(0)}, y:${y.toStringAsFixed(0)}, z:${z.toStringAsFixed(0)}, d:${d.toStringAsFixed(0)}"
        );
      }
    }
  
    @override
    void dispose() {
      _serverService.stopServer();
      _clockTimer?.cancel();
      //_adTimer?.cancel();
      _scrollController.dispose();
      _pickupTimers.values.forEach((t) => t.cancel());
      _pickupTimers.clear();
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
        body: LayoutBuilder(
            builder: (context, constraints) {
              final screenWidth = constraints.maxWidth;
              final screenHeight = constraints.maxHeight;
  
              return Stack(
                fit: StackFit.expand,
                children: [
                  // ================= [Layer 1: 배경 월페이퍼] =================
                  Container(
                    decoration: const BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                            colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1A)]
                        )
                    ),
                    // 실제 로고 파일이 있다면 아래 주석 해제하여 사용
                    // child: Image.asset("assets/images/background.png", fit: BoxFit.cover),
                    child: Center(
                      child: Text("AIO PICKUP TABLE",
                          style: TextStyle(color: Colors.white.withOpacity(0.05), fontSize: 80, fontWeight: FontWeight.bold)
                      ),
                    ),
                  ),

                  CustomPaint(
                    size: Size.infinite,
                    painter: GridPatternPainter(),
                  ),
  
                  // 동영상 (Ad)
                  // FloatingVideoLayer(
                  //   key: _videoLayerKey,
                  //   screenWidth: screenWidth,
                  //   screenHeight: screenHeight,
                  //   currentObstacles: objects.map((e) => e.position).toList(),
                  //   onLog: (msg) => debugPrint("[IPS_ANIM] $msg"),
                  // ),

                  ..._guidePositions.entries.map((entry) {
                    Offset pos = entry.value;
                    return AnimatedPositioned(
                      key: ValueKey("guide_${entry.key}"),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeInOut,
                      left: pos.dx - 90, // 지름 180의 절반
                      top: pos.dy - 90,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: 1.0),
                        duration: const Duration(seconds: 1),
                        builder: (context, val, child) {
                          return Opacity(
                            opacity: val * 0.4, // 희미하게 표시
                            child: CustomPaint(
                              size: const Size(180, 180),
                              painter: GuideCircle(), // guide_circle.dart의 클래스명 확인
                            ),
                          );
                        },
                      ),
                    );
                  }).toList(),

                  // 3-2. 개별 컵 Glow 및 정보 표시
                  ...objects.map((obj) {
                    // 리스트 안이 아니라 함수 블록 안이므로 여기서 변수 계산이 가능합니다.
                    final double displaySize = obj.diameter > 0
                        ? obj.diameter / 2
                        : (obj.uiWidth + obj.uiHeight) / 2;

                    return AnimatedPositioned(
                      key: ValueKey("pos_${obj.id}"),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutQuart,
                      // 정중앙 정렬 계산
                      left: obj.position.dx - (displaySize / 2),
                      top: obj.position.dy - (displaySize / 2),
                      child: RepaintBoundary(
                        child: IPSAnimatedWidget(
                          key: ValueKey("anim_${obj.id}"),
                          isExiting: false,
                          duration: const Duration(milliseconds: 600),
                          child: IndividualCupWidget(
                              object: obj,
                              allObjects: objects,
                              screenWidth: screenWidth,
                              screenHeight: screenHeight,
                            cupColor: _getColorForId(obj.id),
                          ),
                        ),
                      ),
                    );
                  }),

// 3-3. 퇴장 컵
                  ...exitingObjects.map((obj) {
                    final double displaySize = obj.diameter > 0
                        ? obj.diameter / 2
                        : (obj.uiWidth + obj.uiHeight) / 2;

                    return Positioned(
                      key: ValueKey("exit_pos_${obj.id}"),
                      left: obj.position.dx - (displaySize / 2),
                      top: obj.position.dy - (displaySize / 2),
                      child: RepaintBoundary(
                        child: IPSAnimatedWidget(
                          key: ValueKey("anim_${obj.id}_exit"),
                          isExiting: true,
                          duration: const Duration(milliseconds: 400),
                          onExitFinished: () {
                            setState(() {
                              exitingObjects.removeWhere((e) => e.id == obj.id);
                            });
                          },
                          child: IndividualCupWidget(
                            object: obj,
                            allObjects: objects,
                            screenWidth: screenWidth,
                            screenHeight: screenHeight,
                            cupColor: _getColorForId(obj.id),
                          ),
                        ),
                      ),
                    );
                  }), // .ma

                  // (디버깅용) 우측 상단 포트 정보
                  Positioned(
                    top: 40, right: 20,
                    child: Text("Port: ${AppConstants.serverPort}", style: const TextStyle(color: Colors.white24)),
                  ),

                  if (_isConsoleOpen)
                    Positioned(
                      bottom: 80, right: 20,
                      width: 600, height: 800,
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
                                const Text("NETWORK MONITOR", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12)),

                                // 우측 컨트롤 패널 (토글 + 삭제 버튼)
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.white10,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _currentTimeStr,
                                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 12, fontFamily: 'Courier', fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    // 1. Raw Data 토글
                                    Text(
                                        _showRawData ? "RAW" : "EVENT",
                                        style: TextStyle(
                                            color: _showRawData ? Colors.greenAccent : Colors.white54,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold
                                        )
                                    ),
                                    Transform.scale(
                                      scale: 0.7,
                                      child: Switch(
                                        value: _showRawData,
                                        activeColor: Colors.greenAccent,
                                        activeTrackColor: Colors.greenAccent.withOpacity(0.3),
                                        inactiveThumbColor: Colors.grey,
                                        inactiveTrackColor: Colors.white10,
                                        onChanged: (val) {
                                          setState(() {
                                            _showRawData = val;
                                            _addLog("SYS", "Mode Changed: ${val ? 'Raw Data (All)' : 'Event Only (Diff > $_movementThreshold)'}");
                                          });
                                        },
                                      ),
                                    ),

                                    const SizedBox(width: 8),

                                    // 2. 로그 삭제 버튼
                                    TextButton.icon(
                                      onPressed: () => setState(() => _consoleLogs.clear()),
                                      icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 18),
                                      label: const Text("CLEAR", style: TextStyle(color: Colors.white70, fontSize: 12)),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                                  bool isLatestLine = index == _consoleLogs.length - 1;

                                  // [핵심] 이 로그가 현재 활성화된(가장 최신) 프레임에 속하는지 확인
                                  bool isFromCurrentFrame = log.frameId != null && log.frameId == _currentLatestFrameId;

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

                                  /// 로그 색상 추가를 위해 잠시 주석처리
                                  // Color logColor;
                                  //
                                  // // 1. 가장 최신 로그일 경우 -> 밝은 형광색 (Highlight)
                                  // if (isLatest) {
                                  //   logColor = Colors.cyanAccent;
                                  //   // 혹은 Colors.greenAccent, Colors.yellowAccent 등 눈에 띄는 색
                                  // }
                                  // // 2. 지나간 과거 로그일 경우 -> 차분한 색으로 통일
                                  // else {
                                  //   if (log.type == "SYS") {
                                  //     logColor = Colors.grey[700]!; // 시스템 로그는 더 어둡게
                                  //   } else if (log.type == "TX") {
                                  //     logColor = Colors.purpleAccent.withOpacity(0.5); // 송신 로그는 은은한 보라
                                  //   } else {
                                  //     // 일반 수신(RX) 데이터: 이전 로그들은 모두 연한 회색으로 통일
                                  //     logColor = Colors.white38;
                                  //   }
                                  // }
                                  //
                                  // // 화면에 표시할 문자열 조합
                                  // String logText = "[${log.timestamp}][${log.type}] ${log.message}";

                                  return Text(
                                    // logText,
                                    "[${log.timestamp}][${log.type}] ${log.message}",
                                    style: TextStyle(
                                      color: logColor,
                                      fontWeight: isFromCurrentFrame ? FontWeight.bold : FontWeight.normal,
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
                              icon: const Icon(Icons.send, size: 14, color: Colors.orangeAccent),
                              label: const Text("SEND DATA (Test)", style: TextStyle(fontSize: 11)),
                            )
                          ],
                        ),
                      ),
                    ),

                  Positioned(
                    bottom: 20, right: 80,
                    child: FloatingActionButton.small(
                      heroTag: "calibBtn",
                      backgroundColor: Colors.orangeAccent,
                      onPressed: () {
                        setState(() {
                          CoordinateTransformer.resetMatrix();
                          _serverService.sendMessage(jsonEncode({"event_type": "rpi_reboot"}));
                          _isCalibrating = true;
                        });
                      },
                      child: const Icon(Icons.ads_click, color: Colors.black),
                    ),
                  ),
                  // 콘솔 토글 버튼 (우측 하단)
                  Positioned(
                    bottom: 20, right: 20,
                    child: FloatingActionButton.small(
                      backgroundColor: _isConsoleOpen ? Colors.greenAccent : Colors.grey[800],
                      onPressed: () => setState(() => _isConsoleOpen = !_isConsoleOpen),
                      child: Icon(Icons.terminal, color: _isConsoleOpen ? Colors.black : Colors.white),
                    ),
                  ),
                  if (_isCalibrating)
                    CalibrationScreen(
                      currentRawPos: _latestRawForCalib,
                      onCancel: () => setState(() => _isCalibrating = false),
                      onComplete: (data) {
                        setState(() => _isCalibrating = false);
                        _processCalibration(data);
                      },
                    ),
                  ...OrderManager.ghostMemory.map((ghost) {
                    return Positioned(
                      left: ghost.lastPos.dx - 45,
                      top: ghost.lastPos.dy - 45,
                      child: Opacity(
                        opacity: 0.2,
                        child: Container(
                          width: 90, height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            // BorderStyle.dashed 에러 수정: solid로 변경
                            border: Border.all(color: Colors.white, width: 2, style: BorderStyle.solid),
                          ),
                          child: Center(
                            child: Text(ghost.orderNo,
                                style: const TextStyle(color: Colors.white, fontSize: 10)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ],
              );
            }
        ),
      );
    }
    final Map<String, Offset> _guidePositions = {};
    final Random _random = Random();

// [추가] 빈 공간을 찾는 지능형 함수
    Offset _findSafePosition(List<DetectedObject> currentCups) {
      int attempts = 0;
      const double minDistance = 250.0; // 컵과 가이드 사이의 최소 안전 거리

      while (attempts < 50) {
        double x = _random.nextDouble() * (1920 - 400) + 200; // 가로 범위 제한
        double y = _random.nextDouble() * (1080 - 400) + 200; // 세로 범위 제한
        Offset candidate = Offset(x, y);

        // 1. 현재 테이블 위 컵들과의 거리 체크
        bool isFarFromCups = currentCups.every((cup) =>
        (cup.position - candidate).distance > minDistance);

        // 2. 다른 가이드 서클들과의 거리 체크
        bool isFarFromGuides = _guidePositions.values.every((pos) =>
        (pos - candidate).distance > minDistance);

        if (isFarFromCups && isFarFromGuides) return candidate;
        attempts++;
      }
      return const Offset(960, 540); // 실패 시 중앙 반환
    }

// [추가] 주문 대기열 상태와 가이드 좌표 싱크
    void _updateGuidePositions() {
      final pendingOrders = OrderManager.waitingQueue;
      final currentOrderIds = pendingOrders.map((o) => o['orderNo']!).toSet();

      // 1. 사라진 주문(매칭 완료된 주문)의 가이드 좌표 제거
      _guidePositions.removeWhere((orderNo, _) => !currentOrderIds.contains(orderNo));

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
  // 컵을 피해다니는 똑똑한 비디오 플레이어
  class FloatingVideoLayer extends StatefulWidget {
    final double screenWidth;
    final double screenHeight;
    final List<Offset> currentObstacles;
    final Function(String)? onLog;
  
    const FloatingVideoLayer({
      super.key,
      required this.screenWidth,
      required this.screenHeight,
      required this.currentObstacles,
      this.onLog,
    });
  
    @override
    State<FloatingVideoLayer> createState() => FloatingVideoLayerState();
  }
  
  class FloatingVideoLayerState extends State<FloatingVideoLayer> {
    //late VideoPlayerController _videoController;
    late final Player _player;
    late final VideoController _controller;
    bool _isAdActuallyVisible = true;

    Offset _videoPos = Offset.zero;
    double _videoSize = 300.0;
    final Random _random = Random();

    final double minVideoSize = 150.0;
    final double maxVideoSize = 600.0;

    @override
    void initState() {
      super.initState();

      _player = Player();
      _controller = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          // 하드웨어 가속 켜기
          enableHardwareAcceleration: true,
          // 안드로이드 전용 하드웨어 디코더(MediaCodec) 강제 사용 설정
          vo: 'gpu',
          hwdec: 'mediacodec',
        ),
      );
      _player.open(Media('asset://assets/videos/video_stbs2.mp4'));

      _player.setPlaylistMode(PlaylistMode.loop);
      _player.setVolume(0);

      WidgetsBinding.instance.addPostFrameCallback((_) => findNextSafePosition());
    }

    // 영상 길이
    Duration getVideoDuration() {
      Duration duration = _player.state.duration;
      return (duration == Duration.zero) ? const Duration(seconds: 15) : duration;
    }

    // 컵이 사라진 위치로 이동 (Shrink -> Teleport -> Grow 시퀀스)
    Future<void> moveVideoToPosition(Offset targetCenter, List<Offset> otherObstacles) async {
      if (!mounted) return;

      // 1. 현재 자리에서 작아지기 시작
      setState(() {
        _isAdActuallyVisible = false;
      });

      // 2. 애니메이션 시간만큼 대기 (IPSAnimatedWidget의 duration과 동기화)
      // IPSAnimatedWidget의 duration이 800ms라면 800ms~1000ms 대기
      await Future.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;

      // 3. 보이지 않는 상태에서 좌표 및 크기 계산 (순간이동)
      double rawSize = _calculateMaxAvailableSize(targetCenter, otherObstacles);
      double finalSize = rawSize.clamp(minVideoSize, maxVideoSize);

      setState(() {
        _videoPos = targetCenter - Offset(finalSize / 2, finalSize / 2);
        _videoSize = finalSize;
      });

      // 4. 위치 이동이 내부적으로 반영될 짧은 찰나 대기 (Layout 버퍼)
      await Future.delayed(const Duration(milliseconds: 50));

      // 5. 새 위치에서 다시 커지기
      setState(() {
        _isAdActuallyVisible = true;
      });
    }

    // 현재 위치 유지하면서 크기만 조절
    void _adjustSizeToSurroundings() {
      // 현재 비디오의 중심점
      Offset currentCenter = _videoPos + Offset(_videoSize / 2, _videoSize / 2);

      // 현재 위치에서 가능한 최대 크기 계산
      double rawSize = _calculateMaxAvailableSize(currentCenter, widget.currentObstacles);

      // 만약 크기가 너무 작아져서 유지가 불가능하면 이동
      if (rawSize < minVideoSize) {
        print("최소 크기 도달");
        findNextSafePosition(); // 새로운 빈 공간 이동
        return;
      }

      double newSize = rawSize.clamp(minVideoSize, maxVideoSize);

      // 위치는 유지(중심점 고정)하고 크기만 변경
      setState(() {
        _videoSize = newSize;
        // 크기가 변했으니 Top-Left 좌표도 재조정 (중심점 유지)
        _videoPos = currentCenter - Offset(newSize / 2, newSize / 2);
      });
    }

    // 특정 위치에서 가능한 최대 크기(75% 룰) 계산
    double _calculateMaxAvailableSize(Offset center, List<Offset> obstacles) {
      // 1. 벽까지의 거리
      double distToLeft = center.dx;
      double distToRight = widget.screenWidth - center.dx;
      double distToTop = center.dy;
      double distToBottom = widget.screenHeight - center.dy;
      double minToWall = [distToLeft, distToRight, distToTop, distToBottom].reduce(min);

      // 2. 장애물까지의 거리
      double minToObstacle = double.infinity;
      const double obstacleRadius = 100.0;

      if (obstacles.isNotEmpty) {
        for (var obstacle in obstacles) {
          double dist = (obstacle - center).distance - obstacleRadius;
          if (dist < minToObstacle) minToObstacle = dist;
        }
      }

      // 3. 75% 적용
      double maxRadius = min(minToWall, minToObstacle);
      double calculatedSize = (maxRadius * 2) * 0.75;

      return calculatedSize;
    }

    // 빈 공간 찾기 (초기 실행 or 영상 종료 후)
    void findNextSafePosition() {
      if (!mounted) return;

      // 테이블 위에 아무것도 없으면? -> 정중앙
      if (widget.currentObstacles.isEmpty) {
        Offset centerScreen = Offset(widget.screenWidth / 2, widget.screenHeight / 2);
        double rawSize = _calculateMaxAvailableSize(centerScreen, []);

        double finalSize = rawSize.clamp(minVideoSize, maxVideoSize);

        setState(() {
          _videoPos = centerScreen - Offset(finalSize / 2, finalSize / 2);
          _videoSize = finalSize;
        });
        return;
      }

      // 장애물이 있으면 랜덤 탐색
      Offset candidatePos = Offset.zero;
      double finalSize = 300.0;
      bool found = false;
      int attempts = 0;

      while (!found && attempts < 50) {
        // 랜덤 중심점
        double randX = _random.nextDouble() * (widget.screenWidth - 200) + 100;
        double randY = _random.nextDouble() * (widget.screenHeight - 200) + 100;
        Offset centerPoint = Offset(randX, randY);

        double rawSize = _calculateMaxAvailableSize(centerPoint, widget.currentObstacles);

        // 최소 크기 이상 확보되는 곳만 채택
        if (rawSize >= minVideoSize) {
          // ★ 여기서 clamp 적용
          finalSize = rawSize.clamp(minVideoSize, maxVideoSize);
          candidatePos = centerPoint - Offset(finalSize / 2, finalSize / 2);
          found = true;
        }
        attempts++;
      }

      if (found) {
        setState(() {
          _videoPos = candidatePos;
          _videoSize = finalSize;
        });
      }
    }

    @override
    void dispose() {
      _player.dispose();
      super.dispose();
    }
  
    // 부모로부터 컵 위치 데이터가 업데이트되면 실행됨
    @override
    void didUpdateWidget(FloatingVideoLayer oldWidget) {
      super.didUpdateWidget(oldWidget);
      // 주변 환경(컵 위치)이 바뀌면 -> 이동하지 말고 크기만 조절!
      if (widget.currentObstacles != oldWidget.currentObstacles) {
        _adjustSizeToSurroundings();
      }
    }

    @override
    Widget build(BuildContext context) {
      final moveDuration = _isAdActuallyVisible ? const Duration(milliseconds: 1500) : Duration.zero;
      final scaleDuration = _isAdActuallyVisible ? const Duration(milliseconds: 800) : Duration.zero;
      return AnimatedPositioned(
        duration: moveDuration,
        curve: Curves.easeInOut,
        left: _videoPos.dx,
        top: _videoPos.dy,
        child: IPSAnimatedWidget(
          key: const ValueKey("ad_video_anim"),
          isExiting: !_isAdActuallyVisible,
          // 2. 등장(0 -> 1) 속도: 테스트를 위해 10초 설정 (실제로는 2~3초 추천)
          duration: const Duration(milliseconds: 800),
          child: AnimatedContainer(
            duration: scaleDuration,
            curve: Curves.elasticOut, // 크기 변할 때 효과
            width: _videoSize,
            height: _videoSize,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 30, spreadRadius: 5)
                ]
            ),
            child: ClipOval(
              child: Video(
                controller: _controller,
                fit: BoxFit.cover,         // 동그라미 안에 꽉 차게
                controls: NoVideoControls, // 재생 바(UI) 숨기기
              ),
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
        ..color = Colors.cyanAccent.withOpacity(0.15) // 그룹 색상 (사이버틱한 느낌)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 60.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30); // 빛 번짐 효과
  
      final path = Path();
      for (int i = 0; i < objects.length; i++) {
        for (int j = i + 1; j < objects.length; j++) {
          path.moveTo(objects[i].position.dx, objects[i].position.dy);
          // 컵과 컵 사이를 잇는 부드러운 곡선
          path.quadraticBezierTo(
              (objects[i].position.dx + objects[j].position.dx) / 2,
              (objects[i].position.dy + objects[j].position.dy) / 2 + 40,
              objects[j].position.dx, objects[j].position.dy
          );
        }
      }
      canvas.drawPath(path, paint);
    }
  
    @override
    bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
  }

  // [수정 3] Grid System Component (새로 추가됨)
  class GridPatternPainter extends CustomPainter {
    @override
    void paint(Canvas canvas, Size size) {
      final Paint linePaint = Paint()
        ..color = Colors.white.withOpacity(0.1) // 아주 연한 흰색
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      final Paint nodePaint = Paint()
        ..color = Colors.white.withOpacity(0.3) // 교차점은 조금 더 밝게
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

          // (선택 사항) 좌표 텍스트 표시 - 너무 복잡해질 수 있어 주석 처리

        TextSpan span = TextSpan(
          style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 8),
          text: "(${x.toInt()},${y.toInt()})"
        );
        TextPainter tp = TextPainter(text: span, textDirection: TextDirection.ltr);
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
          canvas.drawLine(Offset(startX, startY), Offset(startX, startY + dashWidth), paint);
          startY += dashWidth + dashSpace;
        }
      }
      // 수평선인 경우
      else {
        while (startX < p2.dx) {
          canvas.drawLine(Offset(startX, startY), Offset(startX + dashWidth, startY), paint);
          startX += dashWidth + dashSpace;
        }
      }
    }

    @override
    bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
  }

  class IndividualCupWidget extends StatelessWidget {
    final DetectedObject object;
    final List<DetectedObject> allObjects;
    final double screenWidth;
    final double screenHeight;
    final Color cupColor;
    const IndividualCupWidget({
      super.key,
      required this.object,
      required this.allObjects,
      required this.screenWidth,
      required this.screenHeight,
      required this.cupColor,
    });

    // 주문번호 충돌 시 이동
    double _calculateSafeAngle() {
      const double baseAngle = math.pi / 3.0; // 기본 4시 방향
      double currentScanAngle = baseAngle;

      final double myRadius = (object.diameter > 0 ? object.diameter : 150.0) / 4;
      final double textRadius = myRadius + 18.0;

      // 1. [정밀 튜닝] "NO.101"은 약 25~30도면 충분합니다. (pi / 6)
      // 너무 넓게 잡으면 벽 근처에서 과하게 반응합니다.
      const double textAngularWidth = math.pi / 6.0;

      bool isPerfectlySafe = false;
      int attempts = 0;
      const int maxAttempts = 30; // 보폭이 좁아졌으므로 시도 횟수를 늘립니다.

      // 텍스트가 잘리지 않을 최소한의 여백 (30~35 정도가 적당)
      const double wallPadding = 35.0;

      while (!isPerfectlySafe && attempts < maxAttempts) {
        isPerfectlySafe = true;

        // 시작점, 중간점, 끝점 3포인트 검사
        List<double> anglesToCheck = [
          currentScanAngle,
          currentScanAngle - (textAngularWidth / 2),
          currentScanAngle - textAngularWidth,
        ];

        for (double angle in anglesToCheck) {
          double checkX = object.position.dx + textRadius * math.cos(angle);
          double checkY = object.position.dy + textRadius * math.sin(angle);

          if (checkX < wallPadding ||
              checkX > screenWidth - wallPadding ||
              checkY < wallPadding ||
              checkY > screenHeight - wallPadding) {
            isPerfectlySafe = false;
            break;
          }
        }

        // 2. 컵 충돌 체크는 동일하게 유지
        if (isPerfectlySafe) {
          double centerX = object.position.dx + textRadius * math.cos(currentScanAngle - textAngularWidth / 2);
          double centerY = object.position.dy + textRadius * math.sin(currentScanAngle - textAngularWidth / 2);
          if (allObjects.any((other) => other.id != object.id &&
              (Offset(centerX, centerY) - other.position).distance < (other.diameter/4 + 50))) {
            isPerfectlySafe = false;
          }
        }

        if (!isPerfectlySafe) {
          // 3. [핵심] 도망가는 보폭을 pi/36 (5도)로 매우 촘촘하게 수정
          // 이전 pi/12 (15도)는 너무 성큼성큼 움직여서 금방 10시 방향까지 간 것입니다.
          currentScanAngle += (math.pi / 36.0);
          attempts++;
        }
      }
      return currentScanAngle;
    }

    @override
    Widget build(BuildContext context) {
      final double finalSize = object.diameter > 0
          ? object.diameter / 2
          : (object.uiWidth + object.uiHeight) / 2;

      final double textRadius = (finalSize / 2) + 12;

      final double safeAngle = _calculateSafeAngle();

      final String displayText = object.orderNo == "UNKNOWN"
          ? "UNKNOWN"
          : "NO.${object.orderNo}";

      return SizedBox(
        width: finalSize,
        height: finalSize,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // 그림자/효과 모두 제거하고 깔끔한 원형 테두리만 남김
            Container(
              width: finalSize,
              height: finalSize,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.transparent,
                  border: Border.all(
                    color: cupColor,
                    width: 3, // 테두리 두께 살짝 조정
                  ),
              ),
            ),

            // 2. 우측 하단 주문 번호 라벨
            TweenAnimationBuilder<double>(
              key: ValueKey("text_anim_${object.id}"),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutQuart,
              tween: Tween<double>(end: safeAngle),
              builder: (context, animatedAngle, child) {
                return CustomPaint(
                  size: Size(finalSize, finalSize),
                  painter: ArcTextPainter(
                    text: displayText,
                    radius: textRadius,
                    startAngle: animatedAngle,
                    style: TextStyle(
                      color: cupColor,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                );
              },
            ),

            // 중앙 텍스트 정보
            if (object.uiWidth > 100)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("${object.position.dx.toInt()},${object.position.dy.toInt()}",
                      style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  Text("w:${object.uiWidth.toInt()} h:${object.uiHeight.toInt()}",
                      style: const TextStyle(color: Colors.white70, fontSize: 9)),
                  Text(
                      "D: ${finalSize.toInt()}${object.diameter == 0 ? '(w,h)' : '(d)'}",
                      style: const TextStyle(color: Colors.white70, fontSize: 9)
                  )
                ],
              ),
          ],
        ),
      );
    }
  }