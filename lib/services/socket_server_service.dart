import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../config/app_constants.dart';
import '../models/pickup_data.dart';

class SocketServerService {
  HttpServer? _server;
  WebSocket? _socket;

  final List<String> _allowedIps = [
    "192.168.10.191", // 라즈베리 파이
    "192.168.10.71", // KDS
  ];

  // UI로 데이터와 로그를 전달해줄 콜백 함수들
  final Function(String) onLog;
  final Function(TofFrame) onDataReceived;
  final bool _useIpCheck = false;

  SocketServerService({
    required this.onLog,
    required this.onDataReceived,
  });

  // IP 접근 허용 여부 판단
  bool _isConnectionAllowed(String? clientIp) {
    if (!_useIpCheck) return true;
    if (clientIp == null) return false;
    return _allowedIps.contains(clientIp);
  }

  // 서버 시작
  Future<void> startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, AppConstants.serverPort);
      onLog("서버 시작됨 (IP: ${_server?.address.address} : ${AppConstants.serverPort})");

      if (_useIpCheck) {
        onLog("보안 모드: ON (허용된 IP만 접속 가능)");
      } else {
        onLog("보안 모드: OFF (모든 IP 접속 가능)");
      }

      await for (HttpRequest request in _server!) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocket socket = await WebSocketTransformer.upgrade(request);
          _handleConnection(socket, request);
        } else {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.close();
        }
      }
    } catch (e) {
      onLog("서버 에러: $e");
    }
  }

  DateTime _lastProcessTime = DateTime.now();
  final int _minIntervalMs = 33;

  // 연결 처리
  void _handleConnection(WebSocket socket, HttpRequest request) {
    // 들어온 IP
    final clientIp = request.connectionInfo?.remoteAddress.address;

    // IP 연결 허용 체크
    if (!_isConnectionAllowed(clientIp)) {
      onLog("차단됨: 허용되지 않은 IP ($clientIp)");
      socket.close(WebSocketStatus.policyViolation, "허용되지 않은 IP");
      return; // 함수 종료
    }

    // 허용된 IP 연결
    onLog("인증된 클라이언트 연결됨 ($clientIp)");
    _socket = socket;

    socket.listen(
          (data) {
        final String rawString = data.toString();

        try {
          final Map<String, dynamic> jsonData = jsonDecode(rawString);
          final String type = jsonData['type'] ?? '';

          // 1. [최우선 처리] KDS 주문 데이터인가?
          if (type == 'ORDER_READY') {
            onLog("📢 KDS 주문 수신: ${jsonData['orderNo']}번 (${jsonData['menuName']})");
            // TODO: 여기서 UI의 대기열 리스트에 추가하는 함수를 호출하세요.
            return; // KDS 신호는 처리 끝났으니 여기서 종료
          }

          // 2. [센서 데이터 처리] 기존 ToF 센서 로직
          final now = DateTime.now();
          bool isCritical = rawString.contains("object_appeared") || rawString.contains("object_removed");
          bool isTimeOk = now.difference(_lastProcessTime).inMilliseconds >= _minIntervalMs;

          // 중요 이벤트가 아니고 시간도 안 됐으면 무시
          if (!isCritical && !isTimeOk) return;

          _lastProcessTime = now;

          // ToF 데이터 파싱 및 전송
          final tofFrame = TofFrame.fromJson(jsonData);
          onDataReceived(tofFrame);

        } catch (e) {
          onLog("데이터 해석 에러 ($clientIp): $e");
        }
      },
      onDone: () {
        onLog("연결 종료됨 ($clientIp)");
        if (_socket == socket) _socket = null;
      },
      onError: (error) {
        onLog("통신 에러 ($clientIp): $error");
      },
    );
  }

  void sendMessage(String message) {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      _socket!.add(message);
    } else {
      onLog("전송 실패: 연결된 클라이언트가 없습니다.");
    }
  }

  // 서버 종료
  void stopServer() {
    _server?.close();
    _socket?.close();
    onLog("서버 종료됨");
  }
}