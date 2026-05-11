import 'dart:ui';
import 'dart:math' as math;
import '../models/pickup_data.dart';

class GhostOrder {
  final String orderNo;
  final String menuName;
  final String nickname;
  final Color color;
  final int drinkCount;
  final int foodCount;
  final int bottleCount;
  final Offset lastPos;
  final DateTime disappearedAt;

  GhostOrder({
    required this.orderNo,
    required this.menuName,
    required this.nickname,
    required this.drinkCount,
    required this.foodCount,
    required this.bottleCount,
    required this.color,
    required this.lastPos,
    required this.disappearedAt,
  });
}

class OrderManager {
  // 1. KDS에서 들어온 제조 완료 주문들 (대기열)
  static final List<Map<String, dynamic>> _waitingQueue = [];

  static List<Map<String, dynamic>> get waitingQueue => List.unmodifiable(_waitingQueue);

  // 2. 현재 테이블 위에 올라가 있는 컵(ToF ID)과 매칭된 주문 정보
  // Key: ToF ID (물리 ID), Value: { orderNo, menuName } (비즈니스 데이터)
  static final Map<int, Map<String, dynamic>> _activeMatches = {};

  static final List<GhostOrder> _ghostMemory = [];

  static List<GhostOrder> get ghostMemory {
    _cleanupGhosts();
    // 원본 리스트를 그대로 주지 않고 복사해서 주어 UI 렌더링 중 데이터 오염을 방지함
    return List.unmodifiable(_ghostMemory);
  }

  static const double spatialThreshold = 250.0; // 25cm 이내면 동일 컵으로 간주
  static const Duration ghostDuration = Duration(seconds: 5); // 2초간 기억

  // [KDS 연동] 소켓 서버에서 호출
  static const int maxQueueSize = 50;

  static final Map<String, int> _receivedReadyCounts = {};
  static final Map<String, Map<String, dynamic>> _pendingOrders = {};

  // static void addReadyOrder(String no, String menu, String nickname, int d, int f, int b) {
  //   if (_waitingQueue.length >= maxQueueSize) {
  //     _waitingQueue.removeAt(0); // 너무 오래된 주문은 밀어냄
  //   }
  //   _waitingQueue.add({"orderNo": no, "menuName": menu, "nickname": nickname, "drinkCount": d, "foodCount": f, "bottleCount": b});
  //   print("📦 [Manager] 대기열 추가: $no | 현재 대기: ${_waitingQueue.length}건");
  // }
  static void addReadyOrder(String no, String menu, String nickname, int d, int f, int b, int totalRequired) {
    // 총 필요한 수량 계산
    //int totalRequired = d + f + b;
    if (totalRequired <= 0) totalRequired = 1; // 최소 1잔 보장

    /// 시연 - 1002, 1003, 1004, 1005 완료 처리
    // bool isAlreadyInQueue = _waitingQueue.any((order) => order['orderNo'] == no);
    // bool isAlreadyActive = _activeMatches.values.any((order) => order['orderNo'] == no);
    //
    // if (isAlreadyInQueue || isAlreadyActive) {
    //   print("🛡️ [Manager] $no번 주문은 이미 대기열/테이블에 존재합니다. 중복 신호 차단.");
    //   return;
    // }

    // 1잔 완료 신호가 올 때마다 카운트 1씩 증가
    _receivedReadyCounts[no] = (_receivedReadyCounts[no] ?? 0) + 1;

    // 보류 큐에 최신 데이터 저장
    _pendingOrders[no] = {
      "orderNo": no,
      "menuName": menu,
      "nickname": nickname,
      "drinkCount": d,
      "foodCount": f,
      "bottleCount": b,
      "totalRequired": totalRequired,
      "placedCount": 0 // 테이블에 올라간 컵 수 추적용
    };

    print("📦 [Manager] 제조 완료 수신: $no (${_receivedReadyCounts[no]}/$totalRequired)");

    // 🌟 전체 수량이 모두 완료 신호로 들어왔을 때만 진짜 대기열에 추가!
    if (_receivedReadyCounts[no]! >= totalRequired) {
      if (_waitingQueue.length >= maxQueueSize) {
        _waitingQueue.removeAt(0);
      }
      _waitingQueue.add(_pendingOrders[no]!);
      _receivedReadyCounts.remove(no);
      _pendingOrders.remove(no);
      print("✅ [Manager] $no번 주문 완성! 가이드 서클 생성");
    }
  }

  static Map<String, dynamic>? getMatchedOrder(int tofId) {
    return _activeMatches[tofId];
  }

  // [ToF 연동] 새로운 컵이 감지되었을 때 호출 (기존 유지)
  static Map<String, dynamic>? getOrAssignOrder(int tofId, Offset currentPos, Color initialColor, double physicalDiameter) {
    _cleanupGhosts();
    if (_activeMatches.containsKey(tofId)) {
      _activeMatches[tofId]!['pos'] = currentPos;
      return _activeMatches[tofId];
    }

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
        "nickname": matchedGhost.nickname,
        "color": matchedGhost.color,
        "drinkCount": matchedGhost.drinkCount,
        "foodCount": matchedGhost.foodCount,
        "bottleCount": matchedGhost.bottleCount,
        "pos": currentPos
      };
      _activeMatches[tofId] = reclaimed;
      return reclaimed;
    }

    // if (_waitingQueue.isNotEmpty) {
    //   final assigned = _waitingQueue.removeAt(0);
    //   final newMatch = {
    //     "orderNo": assigned['orderNo']!,
    //     "menuName": assigned['menuName']!,
    //     "nickname": assigned['nickname']!,
    //     "drinkCount": assigned['drinkCount'],
    //     "foodCount": assigned['foodCount'],
    //     "bottleCount": assigned['bottleCount'],
    //     "color": initialColor,
    //     "pos": currentPos
    //   };
    //   _activeMatches[tofId] = newMatch;
    //   return newMatch;
    // }
    if (_waitingQueue.isNotEmpty) {
      final assigned = _waitingQueue.first;

      // 🌟 [핵심 방어 로직] 컵의 지름(크기)을 기반으로 몇 잔이 뭉쳐있는지 추정
      // 매장 컵 사이즈에 맞춰 기준값(Threshold)은 미세 조정이 필요할 수 있습니다.
      int estimatedCupsInBlob = 1;

      // 일반 컵 지름이 80~90mm라고 가정할 때,
      if (physicalDiameter > 130.0 && physicalDiameter <= 220.0) {
        estimatedCupsInBlob = 2; // 2잔이 붙어있음
      } else if (physicalDiameter > 220.0) {
        estimatedCupsInBlob = 3; // 3잔 이상이 붙어있음
      }

      // 붙어있는 잔 수만큼 한 번에 카운트를 올립니다!
      assigned['placedCount'] = (assigned['placedCount'] ?? 0) + estimatedCupsInBlob;

      final newMatch = {
        "orderNo": assigned['orderNo']!,
        "menuName": assigned['menuName']!,
        "nickname": assigned['nickname']!,
        "drinkCount": assigned['drinkCount'],
        "foodCount": assigned['foodCount'],
        "bottleCount": assigned['bottleCount'],
        "color": initialColor,
        "pos": currentPos
      };
      _activeMatches[tofId] = newMatch;

      print("☕ [Manager] 컵 매칭: $tofId -> NO.${assigned['orderNo']} (${assigned['placedCount']}/${assigned['totalRequired']})");

      // 주문된 모든 컵이 전부 테이블에 올라왔다면 그때서야 큐(가이드 서클)에서 완전히 삭제
      if (assigned['placedCount'] >= (assigned['totalRequired'] ?? 1)) {
        _waitingQueue.removeAt(0);
      }
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
          nickname: removed['nickname'] ?? "",
          drinkCount: removed['drinkCount'] ?? 0,
          foodCount: removed['foodCount'] ?? 0,
          bottleCount: removed['bottleCount'] ?? 0,
          color: removed['color'],
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
    g.orderNo == orderNo && (g.lastPos - pos).distance < 30.0
    );
  }

  static Map<int, Map<String, dynamic>> get activeMatches => _activeMatches;
}