import 'dart:ui';
import 'dart:math' as math;
import '../models/pickup_data.dart';

class GhostOrder {
  final String orderNo;
  final String menuName;
  final Offset lastPos;
  final DateTime disappearedAt;

  GhostOrder({
    required this.orderNo,
    required this.menuName,
    required this.lastPos,
    required this.disappearedAt,
  });
}

class OrderManager {
  // 1. KDS에서 들어온 제조 완료 주문들 (대기열)
  static final List<Map<String, String>> _waitingQueue = [];

  static List<Map<String, String>> get waitingQueue => List.unmodifiable(_waitingQueue);

  // 2. 현재 테이블 위에 올라가 있는 컵(ToF ID)과 매칭된 주문 정보
  // Key: ToF ID (물리 ID), Value: { orderNo, menuName } (비즈니스 데이터)
  static final Map<int, Map<String, dynamic>> _activeMatches = {};

  static final List<GhostOrder> _ghostMemory = [];

  static List<GhostOrder> get ghostMemory => _ghostMemory;

  static const double spatialThreshold = 250.0; // 25cm 이내면 동일 컵으로 간주
  static const Duration ghostDuration = Duration(seconds: 2); // 2초간 기억

  // [KDS 연동] 소켓 서버에서 호출
  static void addReadyOrder(String no, String menu) {
    _waitingQueue.add({"orderNo": no, "menuName": menu});
    print("📦 [Manager] 대기열 추가: $no | 현재 대기: ${_waitingQueue.length}건");
  }

  static Map<String, dynamic>? getMatchedOrder(int tofId) {
    return _activeMatches[tofId];
  }

  // [ToF 연동] 새로운 컵이 감지되었을 때 호출 (기존 유지)
  static Map<String, dynamic>? getOrAssignOrder(int tofId, Offset currentPos) {
    if (_activeMatches.containsKey(tofId)) {
      _activeMatches[tofId]!['pos'] = currentPos;
      return _activeMatches[tofId];
    }

    _cleanupGhosts();
    GhostOrder? matchedGhost;

    for (var ghost in _ghostMemory) {
      if ((ghost.lastPos - currentPos).distance < spatialThreshold) {
        matchedGhost = ghost;
        break;
      }
    }

    if (matchedGhost != null) {
      _ghostMemory.remove(matchedGhost);
      final reclaimed = {
        "orderNo": matchedGhost.orderNo,
        "menuName": matchedGhost.menuName,
        "pos": currentPos
      };
      _activeMatches[tofId] = reclaimed;
      return reclaimed;
    }

    if (_waitingQueue.isNotEmpty) {
      final assigned = _waitingQueue.removeAt(0);
      final newMatch = {
        "orderNo": assigned['orderNo']!,
        "menuName": assigned['menuName']!,
        "pos": currentPos
      };
      _activeMatches[tofId] = newMatch;
      return newMatch;
    }
    return null;
  }

  static Map<String, dynamic>? releaseId(int tofId) {
    if (_activeMatches.containsKey(tofId)) {
      final removed = _activeMatches.remove(tofId);

      // [수정] 주문번호가 UNKNOWN이 아닐 때만 유령으로 등록
      if (removed!['orderNo'] != "UNKNOWN") {
        _ghostMemory.add(GhostOrder(
          orderNo: removed['orderNo'],
          menuName: removed['menuName'],
          lastPos: removed['pos'],
          disappearedAt: DateTime.now(),
        ));
        print("⏳ [Manager] No.${removed['orderNo']} 유령 전환");
      } else {
        print("🗑️ [Manager] UNKNOWN 객체 삭제 (유령 등록 안 함)");
      }
      return removed;
    }
    return null;
  }

  static void _cleanupGhosts() {
    final now = DateTime.now();
    _ghostMemory.removeWhere((g) => now.difference(g.disappearedAt) > ghostDuration);
  }

  static bool isGhostStillExists(String orderNo, Offset pos) {
    _cleanupGhosts();
    return _ghostMemory.any((g) =>
    g.orderNo == orderNo && (g.lastPos - pos).distance < 10.0
    );
  }
}