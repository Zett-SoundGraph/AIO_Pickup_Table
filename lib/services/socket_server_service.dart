import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../models/pickup_data.dart';
import 'order_manager.dart';

class SocketServerService {
  HttpServer? _server;
  final List<WebSocket> _allClients = [];
  final Map<String, List<WebSocket>> _roleClients = {
    "KDS": [],
    "TOF_SENSOR": [],
  };

  final List<String> _allowedIps = [
    "192.168.10.191", // 라즈베리 파이
    "192.168.10.71", // KDS
  ];

  // UI로 데이터와 로그를 전달해줄 콜백 함수들
  final Function(String, {bool force}) onLog;
  final Function(TofFrame) onDataReceived;
  final Function(String subType, dynamic value)? onFineTuneCommand;
  final bool _useIpCheck = false;
  final VoidCallback? onOrderReceived;
  final VoidCallback? onCalibrationRequested;

  SocketServerService({
    required this.onLog,
    required this.onDataReceived,
    this.onOrderReceived,
    this.onCalibrationRequested,
    this.onFineTuneCommand,
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
        onLog("보안 모드: ON (허용된 IP만 접속 가능)", force: true);
      } else {
        onLog("보안 모드: OFF (모든 IP 접속 가능)", force: true);
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
  final int _minIntervalMs = 66;
  int _lastObjectCount = 0;

  // 연결 처리
  void _handleConnection(WebSocket socket, HttpRequest request) {
    // 들어온 IP
    final clientIp = request.connectionInfo?.remoteAddress.address;

    // IP 연결 허용 체크
    if (!_isConnectionAllowed(clientIp)) {
      onLog("차단됨: 허용되지 않은 IP ($clientIp)", force: true);
      socket.close(WebSocketStatus.policyViolation, "허용되지 않은 IP");
      return; // 함수 종료
    }
    _allClients.add(socket);
    // 허용된 IP 연결
    onLog("인증된 클라이언트 연결됨 ($clientIp)", force: true);
    debugPrint("인증된 클라이언트 연결됨 ($clientIp)");

    socket.listen(
          (data) {
        final String rawString = data.toString();

        try {
          final Map<String, dynamic> jsonData = jsonDecode(rawString);
          final String type = jsonData['type'] ?? '';

          if (type == 'identify') {
            final String role = jsonData['role'] ?? 'UNKNOWN';
            if (_roleClients.containsKey(role)) {
              // 기존 리스트에 이미 이 소켓이 있다면 추가하지 않도록 방어 로직
              if (!_roleClients[role]!.contains(socket)) {
                _roleClients[role]!.add(socket);
                onLog("✅ 기기 식별 완료: [Role: $role] [IP: $clientIp]", force: true);
              }
            }
            return; // 식별 패킷은 여기서 처리 종료
          }

          if (type == 'FINE_TUNE_CONTROL') {
            final String subType = jsonData['subType'] ?? '';
            final dynamic value = jsonData['value'];
            onFineTuneCommand?.call(subType, value);
            return;
          }

          // 2. KDS 주문 데이터 수신 (기존 유지)
          if (type == 'ORDER_READY') {
            onLog("📢 KDS 주문 수신: ${jsonData['orderNo']}번");
            OrderManager.addReadyOrder(
                jsonData['orderNo'].toString(),
                jsonData['menuName'] ?? "메뉴명 없음",
                jsonData['nickname'] ?? "",
                jsonData['drinkCount'] ?? 0,
                jsonData['foodCount'] ?? 0,
                jsonData['bottleCount'] ?? 0
            );
            onOrderReceived?.call();
            return;
          }

          if (type == 'START_CALIBRATION') {
            onLog("🎯 KDS로부터 원격 캘리브레이션 요청 수신", force: true);
            onCalibrationRequested?.call(); // 메인 화면으로 신호 전달
            return;
          }

          // 2. [센서 데이터 처리] 기존 ToF 센서 로직
          // final now = DateTime.now();
          // bool isCritical = rawString.contains("object_appeared") || rawString.contains("object_removed");
          // bool isTimeOk = now.difference(_lastProcessTime).inMilliseconds >= _minIntervalMs;
          //
          // // 중요 이벤트가 아니고 시간도 안 됐으면 무시
          // if (!isCritical && !isTimeOk) return;

          //_lastProcessTime = now;

          // ToF 데이터 파싱 및 전송
//           final tofFrame = TofFrame.fromJson(jsonData);
//           bool isCountChanged = tofFrame.objects.length != _lastObjectCount;
//           _lastObjectCount = tofFrame.objects.length;
//
//           final now = DateTime.now();
//           bool isTimeOk = now.difference(_lastProcessTime).inMilliseconds >= _minIntervalMs;
//
// // 개수가 변했거나, 시간이 됐을 때만 UI 업데이트 실행
//           if (isCountChanged || isTimeOk) {
//             _lastProcessTime = now;
//             onDataReceived(tofFrame);
//           }
          final tofFrame = TofFrame.fromJson(jsonData);
          onDataReceived(tofFrame);

        } catch (e) {
          onLog("데이터 해석 에러 ($clientIp): $e", force: true);
        }
      },
      onDone: () {
        _allClients.remove(socket);
        _roleClients.forEach((role, list) => list.remove(socket));
        onLog("🔌 연결 종료됨 ($clientIp)", force: true);
      },
      onError: (error) {
        onLog("통신 에러 ($clientIp): $error", force: true);
      },
    );
  }
  void sendMessage(String message) {
    if (_allClients.isEmpty) {
      onLog("⚠️ 전송 실패: 연결된 클라이언트가 없습니다.");
      return;
    }

    for (var client in _allClients) {
      if (client.readyState == WebSocket.open) {
        client.add(message);
      }
    }
    onLog("📡 모든 클라이언트에게 데이터 전송 완료 (${_allClients.length}대)");
  }
  void sendToRole(String role, String message) {
    final targets = _roleClients[role];
    if (targets != null && targets.isNotEmpty) {
      for (var client in targets) {
        if (client.readyState == WebSocket.open) {
          client.add(message);
        }
      }
    } else {
      // 로그가 너무 많이 찍힐 수 있으니 필요할 때만 켭니다.
      onLog("전송 실패: 연결된 $role 클라이언트가 없습니다.");
    }
  }

  // 서버 종료
  void stopServer() {
    // 1. 서버 소켓 닫기
    _server?.close();

    // 2. 모든 활성 소켓 강제 종료
    for (var client in _allClients) {
      try {
        client.close();
      } catch (e) {
        debugPrint("Socket close error: $e");
      }
    }

    // 3. 리스트 비우기
    _allClients.clear();
    _roleClients.forEach((role, list) => list.clear());
    onLog("서버 및 모든 연결 종료됨", force: true);
  }
}