import 'package:flutter/material.dart';

class IPSAnimatedWidget extends StatelessWidget {
  final Widget child;
  final bool isExiting;
  final VoidCallback? onExitFinished;
  final Duration duration;

  const IPSAnimatedWidget({
    required Key key,
    required this.child,
    required this.isExiting,
    this.onExitFinished,
    this.duration = const Duration(milliseconds: 600),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: isExiting ? 0.0 : 1.0),
      duration: duration,
      // 나타날 땐 탄성(easeOutBack), 사라질 땐 가속하며 소멸(easeInQuad)
      curve: isExiting ? Curves.easeInCubic : Curves.easeOutBack,
      onEnd: () {
        if (isExiting) onExitFinished?.call();
      },
      builder: (context, value, child) {
        // RPi 성능 최적화: 가시성이 거의 없을 때는 렌더링을 완전히 제외
        if (value < 0.01 && isExiting) return const SizedBox.shrink();

        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: value,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}