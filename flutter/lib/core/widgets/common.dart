// 共通の部品。見た目は Web 版（html.js）に合わせる。機能側はここの部品で組む。
import 'package:flutter/cupertino.dart' show CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../constants.dart';
import '../theme.dart';

/// 画面の骨組み: 見出し「渋谷マチマチ」＋副題＋縦スクロール（最大幅480）。
class AppPage extends StatelessWidget {
  const AppPage({super.key, required this.children, this.showHeader = true, this.top, this.bottom});
  final List<Widget> children;
  final bool showHeader;

  /// 見出しより上に出すもの（デモバナー等）。
  final Widget? top;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kContentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
              children: [
                ?top,
                if (showHeader) const BrandHeader(),
                ...children,
                ?bottom,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final km = kShibuyaRadiusM / 1000;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: const Text('渋谷マチマチ', style: AppText.h1)),
          const SizedBox(height: 2),
          Text('渋谷駅から半径${km.toStringAsFixed(km == km.roundToDouble() ? 0 : 1)}km限定の1対1待ち合わせ', style: AppText.subtitle),
        ],
      ),
    );
  }
}

/// 白いカード（角丸18・薄い影）。
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 14, offset: Offset(0, 2))],
      ),
      child: child,
    );
  }
}

/// 主ボタン（オレンジ・横幅いっぱい）。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final Widget? icon;

  @override
  Widget build(BuildContext context) => icon == null
      ? FilledButton(onPressed: onPressed, child: Text(label))
      : FilledButton.icon(onPressed: onPressed, icon: icon!, label: Text(label));
}

/// 副ボタン（#efe4da 地・#5b4c42 文字）。
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.selected});
  final String label;
  final VoidCallback? onPressed;
  final Widget? icon;

  /// トグルのとき（aria-pressed 相当）。
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final b = icon == null
        ? ElevatedButton(onPressed: onPressed, child: Text(label))
        : ElevatedButton.icon(onPressed: onPressed, icon: icon!, label: Text(label));
    return selected == null ? b : Semantics(toggled: selected, child: b);
  }
}

class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.textAlign});
  final String text;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(top: 8), child: Text(text, style: AppText.hint, textAlign: textAlign));
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text, style: AppText.label));
}

/// 小さいバッジ（#ffe6db 地・#8a2a10 文字）。
class AppBadge extends StatelessWidget {
  const AppBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: AppColors.brandOrangeSoftBg, borderRadius: BorderRadius.circular(999)),
          child: Text(text, style: AppText.badge),
        ),
      );
}

enum BannerKind { offline, warn }

/// 状態バナー（通信切れ=赤、注意=黄）。読み上げ装置に届くよう liveRegion。
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.kind, required this.text});
  final BannerKind kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      BannerKind.offline => (AppColors.offlineRed, Colors.white),
      BannerKind.warn => (AppColors.warnBg, AppColors.warnText),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// 読み込み中（「読み込んでいます…」）。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.text = '読み込んでいます…'});
  final String text;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AppText.body)),
        ]),
      );
}

/// 行き止まりの画面（停止・満員・期限切れ・エラー）。ボタンは「新しく待ち合わせを作る」→ /new。
class DeadEndCard extends StatelessWidget {
  const DeadEndCard({super.key, required this.message, this.onRestart});
  final String message;

  /// 既定は /new へ。部屋を出る処理を挟みたいときに渡す。
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(liveRegion: true, child: Text(message, style: AppText.body)),
          const SizedBox(height: 16),
          PrimaryButton(label: '新しく待ち合わせを作る', onPressed: onRestart ?? () => context.go('/new')),
        ]),
      );
}

/// ルーターが知らない場所。
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) => const AppPage(children: [DeadEndCard(message: 'ページが見つかりません')]);
}

/// 確認ダイアログ（ネイティブの見た目）。OK なら true。
Future<bool> showConfirm(BuildContext context, {required String message, String ok = 'OK', String cancel = 'キャンセル'}) async {
  final r = await showAdaptiveDialog<bool>(
    context: context,
    builder: (c) => AlertDialog.adaptive(
      content: Text(message),
      actions: [
        adaptiveAction(context: c, onPressed: () => Navigator.of(c).pop(false), child: Text(cancel)),
        adaptiveAction(context: c, onPressed: () => Navigator.of(c).pop(true), isDestructive: true, child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

Widget adaptiveAction({required BuildContext context, required VoidCallback onPressed, required Widget child, bool isDestructive = false}) {
  final platform = Theme.of(context).platform;
  if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
    return CupertinoDialogAction(onPressed: onPressed, isDestructiveAction: isDestructive, child: child);
  }
  return TextButton(onPressed: onPressed, child: child);
}

/// 短い知らせ（コピーしました 等）。Web 版に無かった確認表示を足す。
void showToast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
}

/// 触覚（success=到着・会えた、light=それ以外）。
abstract final class Haptics {
  static Future<void> success() => HapticFeedback.mediumImpact();
  static Future<void> light() => HapticFeedback.lightImpact();
}
