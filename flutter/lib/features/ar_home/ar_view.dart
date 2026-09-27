// AR 画面の重ね描き（人影・端の矢印・中立表示・下端の赤帯）。見た目は ar.js の CSS に合わせる。
// 値はプロバイダから読むだけで、どこにも送らない。センサーの更新でここだけが描き直される（カメラ映像は描き直さない）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core.dart';
import 'ar_camera.dart';
import 'ar_layout.dart';

/// 人影の塗り（rgba(24,24,26,.85)）。
const Color kArSilhouetteFill = Color(0xD918181A);

/// 端の矢印・中立表示の地（黒 60% / 62%）。
const Color kArArrowBg = Color(0x99000000);
const Color kArNeutralBg = Color(0x9E000000);

/// 下端の赤帯（rgba(200,30,30,.94)）。
const Color kArErrorBg = Color(0xF0C81E1E);

/// カメラが使えないときの地。
const Color kArNoCameraBg = Color(0xFF5A5D63);

const List<Shadow> _textShadow = [Shadow(color: Color(0xE6000000), blurRadius: 3, offset: Offset(0, 1))];

/// 向きセンサーの最初の値をこれだけ待っても来なければ「使えない」とみなす。
const Duration kArHeadingWaitTimeout = Duration(seconds: 3);

/// いま AR が指す先を、道順（arGuideProvider）か相手（partnerEstimateProvider）から決める。
ArTarget? resolveArTarget(WidgetRef ref, GeoPoint? me) {
  final guide = ref.watch(arGuideProvider);
  if (guide != null) {
    if (me == null) return null;
    final pick = pickNextWaypoint(guide.route, me);
    if (pick == null) return null;
    final level = guide.destinationLevel;
    return ArTarget(
      point: pick.point,
      name: pick.isLast ? guide.destinationName : '次の曲がり角',
      floorLabel: pick.isLast && level != null ? levelToFloorLabel(level) : null,
      kind: pick.isLast ? ArTargetKind.destination : ArTargetKind.waypoint,
    );
  }
  final partner = ref.watch(partnerEstimateProvider);
  if (partner == null) return null;
  final other = ref.watch(roomControllerProvider.select((v) => v.server?.other));
  final nick = other?.nickname;
  return ArTarget(point: partner, name: (nick == null || nick.isEmpty) ? '相手' : nick, floorLabel: other?.floor);
}

/// 重ね描きの層。
class ArOverlayLayer extends ConsumerWidget {
  const ArOverlayLayer({super.key, required this.cameraStatus, required this.headingTimedOut});
  final ArCameraStatus cameraStatus;

  /// 向きの最初の値を [kArHeadingWaitTimeout] 待っても来なかった。
  final bool headingTimedOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posAsync = ref.watch(positionProvider);
    final me = posAsync.value?.point;
    final headingAsync = ref.watch(headingProvider);
    final heading = headingAsync.value;
    final headingMissing =
        headingAsync.hasError || (headingAsync.hasValue && heading == null) || (heading == null && headingTimedOut);
    final beta = ref.watch(tiltProvider).value;
    final serverSelfFloor = ref.watch(roomControllerProvider.select((v) => v.server?.self?.floor));
    final myFloor = ref.watch(ownFloorProvider) ?? serverSelfFloor;
    final guideMode = ref.watch(arGuideProvider) != null;
    final target = resolveArTarget(ref, me);

    final errors = <String>[
      if (headingMissing) kArOrientationUnavailableMessage,
      if (cameraStatus == ArCameraStatus.denied) kArCameraDeniedMessage,
      if (cameraStatus == ArCameraStatus.unavailable) kArCameraUnavailableMessage,
      if (me == null && posAsync.hasError) kArLocationUnavailableMessage,
    ];
    final needsSettings = cameraStatus == ArCameraStatus.denied || (me == null && posAsync.hasError);

    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        final Widget body;
        if (me == null) {
          body = ArCenterCard(text: posAsync.hasError ? '現在地が取れません' : '現在地を確かめています…');
        } else if (target == null) {
          body = ArCenterCard(text: guideMode ? '道順を待っています…' : '相手の位置を待っています…');
        } else {
          final overlay = computeArOverlay(
            size: size,
            me: me,
            target: target,
            headingDeg: heading,
            betaDeg: beta,
            myFloor: myFloor,
            headingPending: !headingMissing,
          );
          body = switch (overlay) {
            ArNeutral(:final message) => ArCenterCard(text: message),
            ArPerson() => ArPersonMarker(person: overlay),
            ArEdgeArrow() => ArEdgeArrowView(arrow: overlay),
          };
        }
        return Stack(
          children: [
            Positioned.fill(child: body),
            if (errors.isNotEmpty)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: ArErrorBand(messages: errors, showSettings: needsSettings),
              ),
          ],
        );
      },
    );
  }
}

/// 視野の中の人影（上から 階差バッジ・シルエット・名前・距離）。足元（列の下端）を (x, y) に合わせる。
class ArPersonMarker extends StatelessWidget {
  const ArPersonMarker({super.key, required this.person});
  final ArPerson person;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final semantics = [p.name, p.distanceText, ?p.floorBadge].join('、');
    return Stack(
      children: [
        AnimatedPositioned(
          duration: const Duration(milliseconds: 120),
          left: p.x,
          top: p.y,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -1),
            child: Semantics(
              label: '$semanticsの方向',
              container: true,
              excludeSemantics: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.floorBadge != null)
                    Container(
                      key: const ValueKey('ar-floor-badge'),
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(color: AppColors.arBadgeRed, borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        p.floorBadge!,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                  SizedBox(
                    key: const ValueKey('ar-silhouette'),
                    width: p.widthPx,
                    height: p.heightPx,
                    child: const CustomPaint(painter: SilhouettePainter()),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    p.name,
                    softWrap: false,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      shadows: _textShadow,
                    ),
                  ),
                  Text(
                    p.distanceText,
                    softWrap: false,
                    style: const TextStyle(color: Colors.white, fontSize: 13, shadows: _textShadow),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 人影（頭の円＋胴体。ar.js の SVG と同じ形、viewBox 100×200）。顔や人の検出は一切しない、ただの図形。
class SilhouettePainter extends CustomPainter {
  const SilhouettePainter();

  /// viewBox 100×200 の形（ar.js の SILHOUETTE_SVG と同じ座標）。
  static final Path _unit = Path()
    ..moveTo(50, 56)
    ..cubicTo(22, 56, 14, 82, 14, 112)
    ..lineTo(14, 188)
    ..cubicTo(14, 195, 20, 200, 27, 200)
    ..lineTo(38, 200)
    ..cubicTo(43, 200, 45, 195, 45, 188)
    ..lineTo(45, 138)
    ..lineTo(55, 138)
    ..lineTo(55, 188)
    ..cubicTo(55, 195, 57, 200, 62, 200)
    ..lineTo(73, 200)
    ..cubicTo(80, 200, 86, 195, 86, 188)
    ..lineTo(86, 112)
    ..cubicTo(86, 82, 78, 56, 50, 56)
    ..close()
    ..addOval(Rect.fromCircle(center: const Offset(50, 28), radius: 24));

  /// [size] に xMidYMax meet で収めた人影。
  static Path silhouettePath(Size size) {
    final sx = size.width / 100;
    final sy = size.height / 200;
    final s = sx < sy ? sx : sy;
    final dx = (size.width - 100 * s) / 2;
    final dy = size.height - 200 * s;
    // 列優先の 4×4（拡大して平行移動）。
    return _unit.transform(Float64List.fromList([s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1]));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = silhouettePath(size);
    // drop-shadow(0 2px 6px rgba(0,0,0,.7))
    canvas.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = const Color(0xB3000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(path, Paint()..color = kArSilhouetteFill);
  }

  @override
  bool shouldRepaint(covariant SilhouettePainter oldDelegate) => false;
}

/// 視野の外: 端の「振り向いて」矢印。
class ArEdgeArrowView extends StatelessWidget {
  const ArEdgeArrowView({super.key, required this.arrow});
  final ArEdgeArrow arrow;

  @override
  Widget build(BuildContext context) => Align(
    alignment: arrow.toRight ? Alignment.centerRight : Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        key: ValueKey(arrow.toRight ? 'ar-arrow-right' : 'ar-arrow-left'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: kArArrowBg, borderRadius: BorderRadius.circular(22)),
        child: Text(
          arrow.text,
          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}

/// 画面中央の黒い札（中立表示・待っています）。
class ArCenterCard extends StatelessWidget {
  const ArCenterCard({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      key: const ValueKey('ar-center-card'),
      margin: const EdgeInsets.symmetric(horizontal: 14),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(color: kArNeutralBg, borderRadius: BorderRadius.circular(14)),
      child: Semantics(
        liveRegion: true,
        child: PhraseText(
          text,
          alignment: WrapAlignment.center,
          style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.7),
        ),
      ),
    ),
  );
}

/// 下端の赤帯（センサー・カメラ・位置が使えないとき）。必要なら「設定を開く」。
class ArErrorBand extends ConsumerWidget {
  const ArErrorBand({super.key, required this.messages, required this.showSettings});
  final List<String> messages;
  final bool showSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
    top: false,
    child: Container(
      key: const ValueKey('ar-error-band'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: kArErrorBg, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in messages)
                  PhraseText(m, style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.6)),
              ],
            ),
          ),
          if (showSettings)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.underline,
                  ),
                ),
                onPressed: () => unawaited(ref.read(arOpenSettingsProvider)()),
                child: const Text('設定を開く'),
              ),
            ),
        ],
      ),
    ),
  );
}
