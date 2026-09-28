// 相手の方向を示す矢印（自前描画）。html.js の #arrow-wrap / #arrow と同じ見た目:
// 円 180（中心から薄いオレンジのぼかし・枠 brandOrange 35%）、中の矢印 84（SVG "M12 2 L20 20 L12 15.5 L4 20 Z"）。
// 回転は (bearing − heading + 360) % 360。向きが取れないときは北が上。0.25秒で最短の向きに回す。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/core.dart';
import 'room_texts.dart';

class DirectionArrow extends ConsumerStatefulWidget {
  const DirectionArrow({super.key, required this.bearingDeg, this.size = 180, this.arrowSize = 84});

  /// サーバーの bearing_deg（相手への真方位）。null なら回さない（前の向きのまま）。
  final num? bearingDeg;
  final double size;
  final double arrowSize;

  @override
  ConsumerState<DirectionArrow> createState() => _DirectionArrowState();
}

class _DirectionArrowState extends ConsumerState<DirectionArrow> {
  double _cumulative = 0;

  @override
  Widget build(BuildContext context) {
    // 方位は端末の中だけで使う（送らない）。センサーが無い・壊れている → null（北が上）。
    final heading = ref.watch(headingProvider).value;
    final b = widget.bearingDeg;
    if (b != null) _cumulative = nextContinuousAngle(_cumulative, arrowRotationDeg(b, heading));
    return Semantics(
      label: b == null ? '相手の方向を待っています' : directionSpeech(b, heading),
      image: true,
      child: Container(
        width: widget.size,
        height: widget.size,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [AppColors.brandOrange.withValues(alpha: 0.12), AppColors.brandOrange.withValues(alpha: 0)],
            stops: const [0, 0.7],
          ),
          border: Border.all(color: AppColors.brandOrange.withValues(alpha: 0.35), width: 2),
        ),
        alignment: Alignment.center,
        child: AnimatedRotation(
          turns: _cumulative / 360,
          duration: const Duration(milliseconds: 250),
          curve: Curves.ease,
          child: CustomPaint(size: Size.square(widget.arrowSize), painter: const ArrowPainter()),
        ),
      ),
    );
  }
}

/// 上向きの矢印（viewBox 24×24 の "M12 2 L20 20 L12 15.5 L4 20 Z"）。
class ArrowPainter extends CustomPainter {
  const ArrowPainter({this.color = AppColors.brandOrange});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24;
    final sy = size.height / 24;
    final path = Path()
      ..moveTo(12 * sx, 2 * sy)
      ..lineTo(20 * sx, 20 * sy)
      ..lineTo(12 * sx, 15.5 * sy)
      ..lineTo(4 * sx, 20 * sy)
      ..close();
    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(ArrowPainter oldDelegate) => oldDelegate.color != color;
}
