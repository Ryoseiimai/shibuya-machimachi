// ホーム（`/`）の中身。worker/src/lp.js の要点（ヒーロー・3ステップ・安心の設計・できること・OSS・出典）を
// ネイティブの入口として短くまとめる。文言は lp.js のまま（「／」は文節の区切りの目印で、表示には出ない）。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/core.dart';

const String kGithubUrl = 'https://github.com/Ryoseiimai/shibuya-machimachi';

/// プライバシーポリシー・サポートは本番の Worker が配っている（App Store 掲載用と同じページ）。
final Uri kPrivacyUri = Uri.parse('$kProdBaseUrl/privacy');
final Uri kSupportUri = Uri.parse('$kProdBaseUrl/support');
final Uri kGithubUri = Uri.parse(kGithubUrl);

/// リンクを開く。external=false はアプリ内ブラウザ（SFSafariViewController / Custom Tabs）。
typedef HomeLinkOpener = Future<bool> Function(Uri uri, {required bool external});

final homeLinkOpenerProvider = Provider<HomeLinkOpener>(
  (ref) =>
      (uri, {required external}) =>
          launchUrl(uri, mode: external ? LaunchMode.externalApplication : LaunchMode.inAppBrowserView),
);

typedef HomeItem = ({String title, String desc});

/// 「渋谷マチマチができること」7項目（lp.js）。
const List<HomeItem> kHomeFeatures = [
  (title: '距離と矢印', desc: '相手までの距離と方角が、／リアルタイムの矢印で／わかる。'),
  (title: '階の差（上とか下とか）', desc: '同じ渋谷でも／「相手は2つ上の階」まで／わかる。'),
  (title: '道順で案内（上の階・地下も）', desc: '矢印の方向に歩けば／着ける。／「エスカレーターで2階へ」／「階段で地下1階へ」まで案内。／ハチ公像などへ／1人でも使える。'),
  (title: '3D渋谷（PLATEAU）でお互いのピン', desc: '国交省PLATEAUの3D地図に、／自分と相手のピンが／一緒に立つ。'),
  (title: '相手の近くのお店', desc: '相手の位置から／近い順に／お店が3件表示される。'),
  (title: 'カメラ越しに相手の人影（AR）', desc: 'ARモードで／カメラ越しに、／相手がいる方向を／人影で示す。'),
  (title: '「会えた？」をAI（Jev）が判定', desc: '距離・同じ階かどうか・経過時間から、／その場で判定する。'),
];

/// 「安心して使えるための設計」6項目（lp.js・SPEC §6.4）。
const List<String> kHomeTrust = [
  '承認した2人だけに／位置が届く',
  '招待リンクは1回きりで／無効になる',
  'どちらかが押せば、／いつでも即座に／停止できる',
  '待ち合わせは3時間で／自動的に削除される',
  '渋谷駅から1.5km以内でだけ／使える',
  '位置情報は／サーバーのログに／残さない',
];

/// 「使い方は3ステップ」（lp.js）。
const List<HomeItem> kHomeSteps = [
  (title: '作る', desc: 'ニックネームだけで／待ち合わせを作成。'),
  (title: '招待リンクを送る', desc: 'LINEや共有ボタンで、／会う相手に／そのまま送る。'),
  (title: 'お互い承認して会いに行く', desc: '両方が承認した瞬間から、／距離と方角が／届き始める。'),
];

/// 読み上げで1項目ずつ区切る PhraseText（PhraseText だけだと親のノードに混ざる）。
class _Phrase extends StatelessWidget {
  const _Phrase(this.text, {required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Semantics(container: true, child: PhraseText(text, style: style));
}

/// ホームの中身（HomeScreen から使う）。
class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppPage(
    showHeader: false,
    children: [
      const _HomeHeader(),
      const _ResumeCard(),
      const _Hero(),
      const _Section(key: ValueKey('home-steps'), title: '使い方は3ステップ', child: _Steps()),
      const _Section(key: ValueKey('home-trust'), title: '安心して使えるための設計', child: _TrustList()),
      const _FeaturesCard(),
      const _Section(key: ValueKey('home-about'), title: 'このアプリについて', child: AboutLinks()),
      const AttributionText(Attributions.all),
    ],
  );
}

/// 端末に保存した待ち合わせがあれば「続きを開く」（OS にアプリを終了させられたあとでも部屋に戻れる。SPEC §6.4）。
class _ResumeCard extends ConsumerWidget {
  const _ResumeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedRoomProvider).value;
    if (saved == null) return const SizedBox.shrink();
    return AppCard(
      key: const ValueKey('home-resume'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: PhraseText('待ち合わせの／続きがあります', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          ),
          PrimaryButton(label: '続きを開く', onPressed: () => context.go('/r/${saved.roomId}')),
          if (saved.stopPending)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: PhraseText('「共有をやめる」が／まだ相手に／届いていません。／開くと、つながったときに／伝えます。', style: AppText.hint),
            ),
        ],
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) => const Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(padding: EdgeInsets.only(right: 12, top: 2), child: AppMark(size: 48)),
      Expanded(child: BrandHeader()),
    ],
  );
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    const heroTitle = TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: AppColors.ink, height: 1.45);
    const sub = TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.mutedText, height: 1.6);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppBadge('渋谷駅から1.5km限定・無料'),
          Semantics(
            header: true,
            container: true,
            child: const PhraseText('今日、／渋谷の待ち合わせで／困ったから／作りました。', style: heroTitle),
          ),
          const SizedBox(height: 10),
          Semantics(
            label: '渋谷マチマチ — お互いに承認した2人だけで、渋谷で迷わず会える',
            container: true,
            excludeSemantics: true,
            child: Wrap(
              children: [
                Text('渋谷マチマチ', style: sub.copyWith(color: AppColors.brandOrange)),
                for (final p in splitPhrases('　—　／お互いに承認した／2人だけで、／渋谷で／迷わず会える')) Text(p, style: sub),
              ],
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('home-create'),
            onPressed: () => context.go('/new'),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('待ち合わせを作る'),
                Text('（無料・登録なし）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const _Phrase('ニックネームだけで／今すぐ使えます。／アカウント登録は／不要です。', style: AppText.hint),
          const SizedBox(height: 14),
          SecondaryButton(
            key: const ValueKey('home-go'),
            label: '1人で使う：場所へ行く（道順で案内）',
            onPressed: () => context.go('/go'),
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            key: const ValueKey('home-demo'),
            label: 'デモで試す（1台で体験）',
            onPressed: () => context.go('/new?demo=1'),
          ),
        ],
      ),
    );
  }
}

/// 見出し（lp.js の section-heading: 左にオレンジの縦線）＋中身のカード。
class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeading(title),
        const SizedBox(height: 12),
        // ListTile のインクを白いカードの上に出すための透明な Material。
        Material(type: MaterialType.transparency, child: child),
      ],
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    container: true,
    child: Container(
      padding: const EdgeInsets.only(left: 12),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.brandOrange, width: 5)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.ink),
      ),
    ),
  );
}

class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < kHomeSteps.length; i++)
        Padding(
          padding: EdgeInsets.only(bottom: i == kHomeSteps.length - 1 ? 0 : 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: AppColors.brandOrange, shape: BoxShape.circle),
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  container: true,
                  label: '${i + 1}. ${kHomeSteps[i].title}',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kHomeSteps[i].title, style: AppText.label),
                      PhraseText(kHomeSteps[i].desc, style: AppText.hint),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class _TrustList extends StatelessWidget {
  const _TrustList();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final t in kHomeTrust)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 3, right: 8),
                child: Icon(Icons.check_rounded, size: 20, color: AppColors.brandOrange),
              ),
              Expanded(
                child: _Phrase(
                  t,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.ink, height: 1.6),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// できること7項目は長いので折りたたむ（SPEC §6.4「折りたたみでもよい」）。
class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard();

  @override
  Widget build(BuildContext context) => AppCard(
    key: const ValueKey('home-features'),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: const _SectionHeading('渋谷マチマチができること'),
          children: [
            for (final f in kHomeFeatures)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.title, style: AppText.label),
                    PhraseText(f.desc, style: AppText.hint),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 「このアプリについて」: OSS の一言・GitHub・プライバシーポリシー・サポート・ライセンス。
class AboutLinks extends ConsumerWidget {
  const AboutLinks({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, Uri uri, {required bool external}) async {
    var ok = false;
    try {
      ok = await ref.read(homeLinkOpenerProvider)(uri, external: external);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) showToast(context, 'ページを開けませんでした');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget tile(String key, IconData icon, String label, VoidCallback onTap) => ListTile(
      key: ValueKey(key),
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppColors.brandOrangeOnSoft),
      title: Text(label, style: AppText.label),
      trailing: const Icon(Icons.chevron_right, color: AppColors.mutedText),
      onTap: onTap,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PhraseText('オープンソースです。／一緒に作ろう。／コードは全部公開しています。／バグ報告・機能追加・翻訳など、／Issue・PRお待ちしています。', style: AppText.hint),
        const SizedBox(height: 4),
        tile('about-github', Icons.code, 'GitHubで見る', () => unawaited(_open(context, ref, kGithubUri, external: true))),
        tile(
          'about-privacy',
          Icons.privacy_tip_outlined,
          'プライバシーポリシー',
          () => unawaited(_open(context, ref, kPrivacyUri, external: false)),
        ),
        tile(
          'about-support',
          Icons.support_agent,
          'サポート',
          () => unawaited(_open(context, ref, kSupportUri, external: false)),
        ),
        tile(
          'about-licenses',
          Icons.description_outlined,
          'ライセンス',
          () => showLicensePage(
            context: context,
            applicationName: '渋谷マチマチ',
            applicationLegalese: 'コードは MIT License で公開しています。\n$kGithubUrl\n\n${Attributions.all}',
          ),
        ),
        const HintText('コードは MIT License で公開しています。'),
      ],
    );
  }
}

/// アプリのマーク（アイコンと同じ図形。assets/ar_home/branding/src/icon.svg をコードで描いたもの）。
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 48});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: _AppMarkPainter()),
    ),
  );
}

class _AppMarkPainter extends CustomPainter {
  const _AppMarkPainter();

  static const _peach = Color(0xFFFFE6DB);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 1024;
    canvas.save();
    canvas.scale(k);
    const rect = Rect.fromLTWH(0, 0, 1024, 1024);
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(230)));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD9552C), Color(0xFFB8391A)],
        ).createShader(rect),
    );

    // 輪と人影（右上）
    canvas.save();
    canvas.translate(712, 312);
    canvas.scale(0.88);
    canvas.translate(-690, -334);
    const c = Offset(690, 334);
    canvas.drawCircle(c, 138, Paint()..color = _peach.withValues(alpha: 0.18));
    canvas.drawCircle(
      c,
      138,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22
        ..color = _peach,
    );
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: 138)));
    final fill = Paint()..color = _peach;
    canvas.drawCircle(const Offset(690, 296), 50, fill);
    canvas.drawPath(
      Path()
        ..moveTo(690, 360)
        ..cubicTo(620, 360, 590, 400, 590, 460)
        ..lineTo(590, 520)
        ..lineTo(790, 520)
        ..lineTo(790, 460)
        ..cubicTo(790, 400, 760, 360, 690, 360)
        ..close(),
      fill,
    );
    canvas.restore();

    // 相手の方角を指す矢印（左下）
    canvas.save();
    canvas.translate(374, 650);
    canvas.rotate(math.pi / 4);
    final arrow = Path()
      ..moveTo(0, -250)
      ..lineTo(150, 150)
      ..lineTo(0, 70)
      ..lineTo(-150, 150)
      ..close();
    canvas.drawPath(arrow, Paint()..color = Colors.white);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AppMarkPainter oldDelegate) => false;
}
