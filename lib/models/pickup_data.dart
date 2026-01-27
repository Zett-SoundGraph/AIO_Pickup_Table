class TofObject {
  final int id;
  final double x;
  final double y;
  final double z;
  final double diameter;
  final double width;
  final double height;
  final bool isStable;

  TofObject({
    required this.id,
    required this.x,
    required this.y,
    required this.z,
    required this.diameter,
    required this.width,
    required this.height,
    required this.isStable,
  });

  factory TofObject.fromJson(Map<String, dynamic> json) {
    // 안전한 파싱을 위해 null 체크 및 타입 변환 적용
    return TofObject(
      id: json['object_id'] as int? ?? -1,
      x: (json['position']?['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['position']?['y'] as num?)?.toDouble() ?? 0.0,
      z: (json['z_value'] as num?)?.toDouble() ?? 0.0,
      diameter: (json['size']?['diameter'] as num?)?.toDouble() ?? 0.0,
      width: (json['size']?['width'] as num?)?.toDouble() ?? 0.0,
      height: (json['size']?['height'] as num?)?.toDouble() ?? 0.0,
      isStable: json['is_stable'] as bool? ?? false,
    );
  }
}

// 전체 JSON 데이터를 감싸는 큰 그릇 (Timestamp + 객체 리스트)
class TofFrame {
  final String eventType;
  final String timestamp;
  final int frameId;
  final List<TofObject> objects; // 여러 개의 컵을 담을 리스트

  TofFrame({
    required this.eventType,
    required this.timestamp,
    required this.frameId,
    required this.objects,
  });

  factory TofFrame.fromJson(Map<String, dynamic> json) {
    var list = json['objects'] as List? ?? [];
    List<TofObject> objectList = list.map((i) => TofObject.fromJson(i)).toList();

    return TofFrame(
      eventType: json['event_type'] ?? 'unknown',
      timestamp: json['timestamp'] ?? DateTime.now().toIso8601String(),
      frameId: json['frame_id'] as int? ?? 0,
      objects: objectList,
    );
  }

  @override
  String toString() {
    return 'Frame: $frameId | Time: $timestamp | Count: ${objects.length}';
  }
}