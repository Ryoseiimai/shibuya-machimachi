/**
 * トップページ("/")の紹介LP(ランディングページ)。
 *
 * 作成画面(APP_HTML, html.js。パスは"/new")とは別の、マーケティング用の1枚HTMLシート。
 * ビルドステップなし・フレームワークなし・外部CDNなしという既存プロジェクトの方針をそのまま踏襲し、
 * <script>タグを1つも持たない(CSSと<a href>だけで完結する。CSPのscript-src 'self'は
 * そもそもscriptを置かないので無条件に満たす)。
 *
 * OGP画像URL・og:urlは本番の固定ドメインを直接埋め込む。プレビューURLやローカルの
 * `wrangler dev`のオリジンに依存させず、SNSのリンクカードは常に本番URLを指すべきという判断。
 */
import { Parser, jaModel } from "budoux";

const PROD_ORIGIN = "https://shibuya-machimachi.kaeru3160.workers.dev";
const OGP_IMAGE_URL = `${PROD_ORIGIN}/lp/ogp.png`;
const PAGE_TITLE = "渋谷マチマチ｜渋谷で迷わず会える1対1の待ち合わせ";
const PAGE_DESCRIPTION =
  "渋谷駅から半径1.5km限定、お互いに承認した2人だけで距離と方角を共有する待ち合わせアプリ。登録不要・無料。オープンソース。";

/**
 * 見出し・本文の日本語テキストをBudouX(Google製の文節分割ライブラリ)で文節ごとに区切り、
 * 区切り目に<wbr>を挿入するヘルパー。「文節の途中で改行され、助詞や句読点(？で終わる文の
 * ？だけ、「〜される」の「る」だけ等)が次行に孤立する」問題を、手作業の<wbr>配置に頼らず
 * 機械的に防ぐ。Parser/jaModelはモジュール読み込み時(Workerのisolate起動時)に1回だけ
 * インスタンス化し、LP_HTML自体も同じタイミングで1回だけ組み立てられるので、リクエストの
 * たびに再計算はしない。プレーンな日本語テキストにのみ使うこと(BudouXの分割モデルは1文字
 * ずつのスコアリングでHTMLタグを想定していないため、<span>等を含む文字列を渡すとタグの
 * 文字自体を区切り対象にしてしまう。タグを含む箇所はタグの外側のテキストだけを渡す)。
 */
const jaParser = new Parser(jaModel);
const wbr = (text) => jaParser.parse(text).join("<wbr>");

export const LP_HTML = String.raw`<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${PAGE_TITLE}</title>
<meta name="description" content="${PAGE_DESCRIPTION}">
<link rel="canonical" href="${PROD_ORIGIN}/">
<meta property="og:type" content="website">
<meta property="og:title" content="${PAGE_TITLE}">
<meta property="og:description" content="${PAGE_DESCRIPTION}">
<meta property="og:url" content="${PROD_ORIGIN}/">
<meta property="og:image" content="${OGP_IMAGE_URL}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:locale" content="ja_JP">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${PAGE_TITLE}">
<meta name="twitter:description" content="${PAGE_DESCRIPTION}">
<meta name="twitter:image" content="${OGP_IMAGE_URL}">
<style>
  :root {
    color-scheme: light;
    --brand-orange: #c8431f;
    --brand-orange-soft-bg: #ffe6db;
    --brand-orange-on-soft: #8a2a10;
    --ink: #201a15;
    --muted-text: #5b5148;
    --border-soft: #ece5dc;
    --chip-bg: #f5f1ec;
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; padding: 0; }
  body {
    font-family: -apple-system, "Hiragino Sans", "Yu Gothic", sans-serif;
    background: #ffffff; color: var(--ink); line-height: 1.75; font-size: 16px;
    /* word-break/overflow-wrapは継承されるので、ページ全体の見出し・本文がここで
       まとめて「文節の途中では改行しない(keep-all)。それでも収まらない時だけ最後の
       手段としてどこでも折り返す(anywhere)」の対象になる。 */
    word-break: keep-all; overflow-wrap: anywhere;
  }
  img { max-width: 100%; display: block; }
  a { color: inherit; }
  .wrap { max-width: 1040px; margin: 0 auto; padding: 0 24px; }
  section { padding: 56px 0; }
  h1, h2 { line-height: 1.45; margin: 0; }
  .kicker {
    display: inline-flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 800;
    color: var(--brand-orange-on-soft); background: var(--brand-orange-soft-bg);
    padding: 5px 12px; border-radius: 999px; margin-bottom: 16px;
  }
  .section-heading {
    font-size: clamp(22px, 3.6vw, 30px); font-weight: 800; margin-bottom: 28px;
    padding-left: 14px; border-left: 5px solid var(--brand-orange);
  }

  /* --- 1. ヒーロー --- */
  .hero { padding: 48px 0 40px; }
  .hero .wrap {
    display: flex; flex-direction: column; align-items: center; gap: 32px; text-align: center;
  }
  .hero h1 {
    font-size: clamp(26px, 5.4vw, 42px); font-weight: 900; letter-spacing: 0.01em;
  }
  .hero .sub {
    font-size: clamp(16px, 2.4vw, 19px); color: var(--muted-text); font-weight: 700;
    margin: 18px 0 26px;
  }
  .hero .sub .brand { color: var(--brand-orange); }
  .cta-btn {
    display: inline-flex; flex-direction: column; align-items: center; gap: 4px;
    font-size: 18px; font-weight: 800; padding: 16px 28px;
    border-radius: 16px; background: var(--brand-orange); color: #fff; text-decoration: none;
    box-shadow: 0 10px 24px rgba(200,67,31,0.28);
  }
  .cta-btn-note { font-size: 13px; font-weight: 700; }
  .cta-note { font-size: 13px; color: var(--muted-text); margin-top: 12px; }
  .hero-shot {
    border-radius: 22px; border: 1px solid var(--border-soft);
    box-shadow: 0 16px 40px rgba(32,26,21,0.14); overflow: hidden; max-width: 300px; width: 100%;
  }
  @media (min-width: 780px) {
    .hero .wrap { flex-direction: row; text-align: left; align-items: center; }
    .hero .copy { flex: 1; }
    .hero .shot-col { flex: 0 0 320px; }
  }

  /* --- 2. 困りごと --- */
  .pain { background: var(--chip-bg); }
  .pain-list { list-style: none; margin: 0; padding: 0; display: grid; gap: 18px; }
  .pain-list li {
    background: #fff; border: 1px solid var(--border-soft); border-radius: 16px;
    padding: 18px 20px; font-size: 16px; font-weight: 600;
  }
  @media (min-width: 700px) { .pain-list { grid-template-columns: 1fr 1fr; } }

  /* --- 3. できること --- */
  .features { list-style: none; margin: 0; padding: 0; display: grid; gap: 24px; }
  @media (min-width: 700px) { .features { grid-template-columns: 1fr 1fr; } }
  .feature-item { display: flex; gap: 14px; align-items: flex-start; }
  .feature-icon {
    flex: 0 0 auto; width: 44px; height: 44px; border-radius: 12px; background: var(--chip-bg);
    display: flex; align-items: center; justify-content: center;
  }
  .feature-icon svg { width: 24px; height: 24px; color: var(--ink); }
  .feature-title { font-weight: 800; font-size: 16px; margin: 0 0 4px; }
  .feature-desc { font-size: 14px; color: var(--muted-text); margin: 0; }
  .features-shot-wrap { margin-top: 36px; text-align: center; }
  .features-shot {
    border-radius: 22px; border: 1px solid var(--border-soft);
    box-shadow: 0 16px 40px rgba(32,26,21,0.12); display: inline-block; overflow: hidden;
    max-width: 300px; width: 100%;
  }

  /* --- 4. 安心の設計 --- */
  .trust { background: var(--chip-bg); }
  .trust-list { list-style: none; margin: 0; padding: 0; display: grid; gap: 16px; }
  @media (min-width: 700px) { .trust-list { grid-template-columns: 1fr 1fr; } }
  .trust-list li {
    display: flex; gap: 10px; align-items: flex-start; font-size: 15px; font-weight: 700;
    background: #fff; border: 1px solid var(--border-soft); border-radius: 14px; padding: 14px 16px;
  }
  .trust-list svg { flex: 0 0 auto; width: 20px; height: 20px; color: var(--brand-orange); margin-top: 1px; }

  /* --- 5. 使い方3ステップ --- */
  .steps { list-style: none; margin: 0; padding: 0; display: grid; gap: 24px; counter-reset: step; }
  @media (min-width: 780px) { .steps { grid-template-columns: repeat(3, 1fr); } }
  .steps li { text-align: center; padding: 0 8px; }
  .step-num {
    width: 44px; height: 44px; border-radius: 50%; background: var(--brand-orange); color: #fff;
    font-weight: 900; font-size: 19px; display: flex; align-items: center; justify-content: center;
    margin: 0 auto 14px;
  }
  .step-title { font-weight: 800; font-size: 16px; margin: 0 0 6px; }
  .step-desc { font-size: 14px; color: var(--muted-text); margin: 0; }

  /* --- 6. OSS --- */
  .oss { text-align: center; }
  .oss p { max-width: 560px; margin: 16px auto 24px; color: var(--muted-text); font-size: 15px; }
  .oss-btn {
    display: inline-flex; align-items: center; gap: 8px; font-weight: 800; font-size: 15px;
    padding: 12px 22px; border-radius: 14px; border: 2px solid var(--ink); color: var(--ink);
    text-decoration: none;
  }
  .oss-btn svg { width: 18px; height: 18px; }

  /* --- 閉じのCTA --- */
  .closing-cta { text-align: center; background: var(--chip-bg); }

  /* --- 7. フッター --- */
  footer { padding: 32px 0 44px; }
  .footer-attribution { font-size: 12px; color: var(--muted-text); text-align: center; line-height: 1.7; }
  .footer-license { font-size: 12px; color: var(--muted-text); text-align: center; margin-top: 8px; }
  .footer-links { text-align: center; margin-top: 14px; font-size: 13px; }
  .footer-links a { color: var(--brand-orange-on-soft); font-weight: 700; text-decoration: underline; }
</style>
</head>
<body>

<section class="hero">
  <div class="wrap">
    <div class="copy">
      <span class="kicker">渋谷駅から1.5km限定・無料</span>
      <h1>${wbr("今日、渋谷の待ち合わせで困ったから作りました。")}</h1>
      <p class="sub"><span class="brand">渋谷マチマチ</span> — ${wbr("お互いに承認した2人だけで、渋谷で迷わず会える")}</p>
      <a class="cta-btn" href="/new"><span class="cta-btn-main">待ち合わせを作る</span><span class="cta-btn-note">（無料・登録なし）</span></a>
      <p class="cta-note">${wbr("ニックネームだけで今すぐ使えます。アカウント登録は不要です。")}</p>
    </div>
    <div class="shot-col">
      <img class="hero-shot" src="/lp/top-390.png" srcset="/lp/top-240.png 240w, /lp/top-390.png 390w" sizes="(min-width: 780px) 300px, 70vw" width="390" height="844" alt="渋谷マチマチのアプリ画面。相手までの距離155mと方角の矢印が表示されている" loading="lazy">
    </div>
  </div>
</section>

<section class="pain">
  <div class="wrap">
    <h2 class="section-heading">${wbr("渋谷の待ち合わせ、こんなことになっていませんか？")}</h2>
    <ul class="pain-list">
      <li>${wbr("渋谷駅は地下も上もあって、「どこ？」「何階？」を何度もやり取りすることになる。")}</li>
      <li>${wbr("地図アプリで位置を送っても、相手が今どこにいるのかは結局よくわからない。")}</li>
    </ul>
  </div>
</section>

<section class="features">
  <div class="wrap">
    <h2 class="section-heading">渋谷マチマチができること</h2>
    <ul class="features">
      <li class="feature-item">
        <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7l3 8-3-2-3 2z" fill="currentColor" stroke="none"/></svg></span>
        <span>
          <p class="feature-title">${wbr("距離と矢印")}</p>
          <p class="feature-desc">${wbr("相手までの距離と方角が、リアルタイムの矢印でわかる。")}</p>
        </span>
      </li>
      <li class="feature-item">
        <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 21V3M8 3L5 6M8 3l3 3"/><path d="M16 3v18M16 21l-3-3M16 21l3-3"/></svg></span>
        <span>
          <p class="feature-title">${wbr("階の差（上とか下とか）")}</p>
          <p class="feature-desc">${wbr("同じ渋谷でも「相手は2つ上の階」までわかる。")}</p>
        </span>
      </li>
      <li class="feature-item">
        <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 3a3.4 3.4 0 0 0-3.4 3.4c0 2.5 3.4 6.6 3.4 6.6s3.4-4.1 3.4-6.6A3.4 3.4 0 0 0 7 3z"/><path d="M17 9a2.6 2.6 0 0 0-2.6 2.6c0 1.9 2.6 5 2.6 5s2.6-3.1 2.6-5A2.6 2.6 0 0 0 17 9z"/></svg></span>
        <span>
          <p class="feature-title">${wbr("3D渋谷（PLATEAU）でお互いのピン")}</p>
          <p class="feature-desc">${wbr("国交省PLATEAUの3D地図に、自分と相手のピンが一緒に立つ。")}</p>
        </span>
      </li>
      <li class="feature-item">
        <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 9l1-5h14l1 5"/><rect x="5" y="9" width="14" height="11" rx="1"/><rect x="10" y="14" width="4" height="6"/></svg></span>
        <span>
          <p class="feature-title">${wbr("相手の近くのお店")}</p>
          <p class="feature-desc">${wbr("相手の位置から近い順にお店が3件表示される。")}</p>
        </span>
      </li>
      <li class="feature-item">
        <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="7" width="18" height="13" rx="2"/><path d="M8 7l2-3h4l2 3"/><circle cx="12" cy="13.5" r="3.4"/></svg></span>
        <span>
          <p class="feature-title">${wbr("カメラ越しに相手の人影（AR）")}</p>
          <p class="feature-desc">${wbr("ARモードでカメラ越しに、相手がいる方向を人影で示す。")}</p>
        </span>
      </li>
      <li class="feature-item">
        <span class="feature-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M8 12.3l2.6 2.6L16 9"/></svg></span>
        <span>
          <p class="feature-title">${wbr("「会えた？」をAI（Jev）が判定")}</p>
          <p class="feature-desc">${wbr("距離・同じ階かどうか・経過時間から、その場で判定する。")}</p>
        </span>
      </li>
    </ul>
    <div class="features-shot-wrap">
      <img class="features-shot" src="/lp/shops3d-390.png" srcset="/lp/shops3d-240.png 240w, /lp/shops3d-390.png 390w" sizes="(min-width: 780px) 300px, 70vw" width="390" height="844" alt="3D渋谷の地図に自分と相手のピン、近くのお店リストが表示されているアプリ画面" loading="lazy">
    </div>
  </div>
</section>

<section class="trust">
  <div class="wrap">
    <h2 class="section-heading">安心して使えるための設計</h2>
    <ul class="trust-list">
      <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 12l5 5L20 6"/></svg>${wbr("承認した2人だけに位置が届く")}</li>
      <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 12l5 5L20 6"/></svg>${wbr("招待リンクは1回きりで無効になる")}</li>
      <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 12l5 5L20 6"/></svg>${wbr("どちらかが押せば、いつでも即座に停止できる")}</li>
      <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 12l5 5L20 6"/></svg>${wbr("待ち合わせは3時間で自動的に削除される")}</li>
      <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 12l5 5L20 6"/></svg>${wbr("渋谷駅から1.5km以内でだけ使える")}</li>
      <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 12l5 5L20 6"/></svg>${wbr("位置情報はサーバーのログに残さない")}</li>
    </ul>
  </div>
</section>

<section class="how">
  <div class="wrap">
    <h2 class="section-heading">使い方は3ステップ</h2>
    <ol class="steps">
      <li>
        <div class="step-num">1</div>
        <p class="step-title">作る</p>
        <p class="step-desc">${wbr("ニックネームだけで待ち合わせを作成。")}</p>
      </li>
      <li>
        <div class="step-num">2</div>
        <p class="step-title">招待リンクを送る</p>
        <p class="step-desc">${wbr("LINEや共有ボタンで、会う相手にそのまま送る。")}</p>
      </li>
      <li>
        <div class="step-num">3</div>
        <p class="step-title">お互い承認して会いに行く</p>
        <p class="step-desc">${wbr("両方が承認した瞬間から、距離と方角が届き始める。")}</p>
      </li>
    </ol>
  </div>
</section>

<section class="oss">
  <div class="wrap">
    <h2 class="section-heading" style="border-left:none;padding-left:0;">${wbr("オープンソースです。一緒に作ろう")}</h2>
    <p>${wbr("渋谷マチマチのコードは全部公開しています。バグ報告・機能追加・翻訳など、Issue・PRお待ちしています。初心者向けの good first issue もあります。")}</p>
    <a class="oss-btn" href="https://github.com/Ryoseiimai/shibuya-machimachi">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="8 6 2 12 8 18"/><polyline points="16 6 22 12 16 18"/></svg>
      GitHubで見る
    </a>
  </div>
</section>

<section class="closing-cta">
  <div class="wrap">
    <a class="cta-btn" href="/new"><span class="cta-btn-main">待ち合わせを作る</span><span class="cta-btn-note">（無料・登録なし）</span></a>
  </div>
</section>

<footer>
  <div class="wrap">
    <p class="footer-attribution">建物: 出典 国土交通省 3D都市モデルPLATEAU（渋谷区, CC&nbsp;BY&nbsp;4.0）／地図: 地理院タイル／店舗: © OpenStreetMap&nbsp;contributors (ODbL)</p>
    <p class="footer-license">コードは MIT License で公開しています。</p>
    <p class="footer-links"><a href="https://github.com/Ryoseiimai/shibuya-machimachi">github.com/Ryoseiimai/shibuya-machimachi</a></p>
    <p class="footer-links"><a href="/privacy">プライバシーポリシー</a>　<a href="/support">サポート</a></p>
  </div>
</footer>

</body>
</html>`;
