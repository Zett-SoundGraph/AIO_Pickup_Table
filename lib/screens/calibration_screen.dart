// lib/screens/calibration_screen.dart
import 'package:flutter/material.dart';

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

  // 디스플레이상의 9개 목표 지점 (1920x1080 기준 적정 마진 적용)
  final List<Offset> targetPoints = [
    const Offset(150, 150),   const Offset(960, 150),   const Offset(1770, 150),
    const Offset(150, 540),   const Offset(960, 540),   const Offset(1770, 540),
    const Offset(150, 930),   const Offset(960, 930),   const Offset(1770, 930),
  ];

  void _handleCapture() {
    if (widget.currentRawPos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("현재 인식된 객체가 없습니다. 컵을 올려주세요.")),
      );
      return;
    }

    setState(() {
      collectedPairs.add(CalibrationPair(widget.currentRawPos!, targetPoints[currentStep]));
      if (currentStep < targetPoints.length - 1) {
        currentStep++;
      } else {
        widget.onComplete(collectedPairs);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.95),
      child: Stack(
        children: [
          // 가이드 텍스트
          Positioned(
            top: 100, left: 0, right: 0,
            child: Column(
              children: [
                Text("Calibration Mode: Step ${currentStep + 1} / 9",
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                const Text("붉은 원 안에 컵을 정확히 놓은 후 캡처 버튼을 누르세요.",
                    style: TextStyle(color: Colors.white70, fontSize: 18)),
                const SizedBox(height: 20),
                if (widget.currentRawPos != null)
                  Text("Sensor Data -> X: ${widget.currentRawPos!.dx.toInt()}, Y: ${widget.currentRawPos!.dy.toInt()}",
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontFamily: 'Courier')),
              ],
            ),
          ),

          // 타겟 포인트 (붉은 원)
          Positioned(
            left: targetPoints[currentStep].dx - 60,
            top: targetPoints[currentStep].dy - 60,
            child: Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.redAccent, width: 4),
                boxShadow: [BoxShadow(color: Colors.redAccent.withOpacity(0.3), blurRadius: 20)],
              ),
              child: const Center(child: Icon(Icons.add, color: Colors.redAccent, size: 40)),
            ),
          ),

          // 컨트롤 버튼
          Positioned(
            bottom: 50, left: 0, right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text("CANCEL", style: TextStyle(color: Colors.white54, fontSize: 16)),
                ),
                const SizedBox(width: 40),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                  ),
                  onPressed: _handleCapture,
                  child: const Text("CAPTURE DATA", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}