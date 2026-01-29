// lib/services/order_manager.dart
import '../models/pickup_data.dart';

class OrderManager {
  // 1. KDS에서 들어온 제조 완료 주문들 (대기열)
  static final List<Map<String, String>> _waitingQueue = [];

  static List<Map<String, String>> get waitingQueue => List.unmodifiable(_waitingQueue);

  // 2. 현재 테이블 위에 올라가 있는 컵(ToF ID)과 매칭된 주문 정보
  // Key: ToF ID (물리 ID), Value: { orderNo, menuName } (비즈니스 데이터)
  static final Map<int, Map<String, String>> _activeMatches = {};

  // [KDS 연동] 소켓 서버에서 호출
  static void addReadyOrder(String no, String menu) {
    _waitingQueue.add({"orderNo": no, "menuName": menu});
    print("📦 [Manager] 대기열 추가: $no | 현재 대기: ${_waitingQueue.length}건");
  }

  static Map<String, String>? getMatchedOrder(int tofId) {
    if (_activeMatches.containsKey(tofId)) {
      return _activeMatches[tofId];
    }
    return null; // 매칭된 게 없으면 그냥 null 반환 (새로 할당 안 함)
  }

  // [ToF 연동] 새로운 컵이 감지되었을 때 호출 (기존 유지)
  static Map<String, String>? getOrAssignOrder(int tofId, {String? forceOrderNo}) {
    // 1. 이미 매칭된 ID라면 그대로 반환
    if (_activeMatches.containsKey(tofId)) {
      return _activeMatches[tofId];
    }

    // 2. 강제 할당 모드 (공간 추적 성공 시 사용)
    if (forceOrderNo != null) {
      final forcedOrder = {"orderNo": forceOrderNo, "menuName": "기존 주문 승계"};
      _activeMatches[tofId] = forcedOrder;
      print("📌 [Manager] ID $tofId 에 기존 번호 NO.$forceOrderNo 강제 승계 완료");
      return forcedOrder;
    }

    // 3. 일반 할당 모드 (신규 컵 등장 시)
    if (_waitingQueue.isNotEmpty) {
      final assignedOrder = _waitingQueue.removeAt(0);
      _activeMatches[tofId] = assignedOrder;
      print("🎯 [Manager] ID $tofId <-> 주문 ${assignedOrder['orderNo']} 신규 할당");
      return assignedOrder;
    }

    return null;
  }

  // releaseId가 삭제된 주문 정보를 반환하도록 수정
  static Map<String, String>? releaseId(int tofId) {
    if (_activeMatches.containsKey(tofId)) {
      final removedOrder = _activeMatches.remove(tofId);
      print("🗑️ [Manager] ID $tofId (주문 ${removedOrder?['orderNo']}) 매칭 해제 및 반환");
      return removedOrder;
    }
    return null;
  }
}