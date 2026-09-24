// 渋谷マチマチ AR部品（単体）
// スマホ背面カメラ映像の上に、待ち合わせ相手がいる方向へ人影(シルエット)と距離を重ねて表示する。
// 映っている他人の検出・識別は一切行わない。相手1人の位置(緯度経度・階)だけを方向として描画する。
// カメラ映像はどこにも送信・保存しない（getUserMediaのMediaStreamをvideo要素に流すだけ）。
//
// 使い方:
//   import { mountAR } from './ar.js';
//   const ar = mountAR(document.getElementById('ar-container'));
//   startButton.onclick = () => ar.start();           // 必ずユーザー操作(クリック)から呼ぶこと
//   ar.setMe(35.658, 139.7016, 1);                     // 自分の緯度経度・階
//   ar.setPartner(35.659, 139.7026, 3, 'たかし');       // 相手の緯度経度・階・名前
//   // 不要になったら ar.stop();

import {
  bearingDegrees,
  distanceMeters,
  normalizeAngleDiff,
  formatDistance,
  floorIndicatorText,
  clamp,
  DEFAULT_FOV_DEGREES,
} from './geo.js';

// --- 描画チューニング用の定数（マジックナンバー排除） ---
const BETA_NEUTRAL_DEG = 90; // DeviceOrientationEventのbeta基準値（スマホを縦に構えて前方に向けた状態を想定）
const VERTICAL_PX_PER_DEG = 4; // betaのズレ1度あたりの縦方向オフセット(px)
const VERTICAL_OFFSET_CLAMP = 160; // 縦方向オフセットの最大値(px)
const BASE_Y_RATIO = 0.56; // 画面高さに対する基準の足元位置（目線あたりの簡易近似）
const HORIZONTAL_MARGIN_RATIO = 0.42; // 画面幅に対する左右振れ幅の比率（端に張り付かないよう余白を残す）
const SIZE_SCALE_CONST = 2600; // 人影サイズ = SIZE_SCALE_CONST / 距離(m) の概算スケール
const SIZE_MIN_PX = 26;
const SIZE_MAX_PX = 200;

let styleInjected = false;

function injectStyleOnce() {
  if (styleInjected) return;
  styleInjected = true;
  const style = document.createElement('style');
  style.textContent = `
.mm-ar-root { position: relative; overflow: hidden; background: #111; }
.mm-ar-video { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; background:#222; }
.mm-ar-fallback-bg { position:absolute; inset:0; background:#5a5d63; display:flex; align-items:center; justify-content:center; color:#ddd; font-size:12px; font-family:-apple-system,"Hiragino Sans",sans-serif; text-align:center; padding:16px; box-sizing:border-box; }
.mm-ar-fallback-bg[hidden] { display:none; }
.mm-ar-overlay { position:absolute; inset:0; pointer-events:none; }
.mm-ar-person { position:absolute; left:0; top:0; transform: translate(-50%,-100%); display:flex; flex-direction:column; align-items:center; filter: drop-shadow(0 2px 6px rgba(0,0,0,.7)); }
.mm-ar-person[hidden] { display:none; }
.mm-ar-silhouette-svg { fill: rgba(24,24,26,.85); display:block; }
.mm-ar-name, .mm-ar-distance, .mm-ar-floor { color:#fff; text-shadow: 0 1px 3px rgba(0,0,0,.9); font-family:-apple-system,"Hiragino Sans",sans-serif; text-align:center; white-space:nowrap; }
.mm-ar-name { font-size:14px; font-weight:700; margin-top:2px; }
.mm-ar-distance { font-size:13px; }
.mm-ar-floor { font-size:12px; font-weight:700; color:#fff; background:rgba(230,70,70,.9); border-radius:10px; padding:1px 8px; margin-bottom:4px; }
.mm-ar-arrow { position:absolute; top:50%; transform:translateY(-50%); color:#fff; background:rgba(0,0,0,.6); padding:10px 14px; border-radius:22px; font-size:15px; font-weight:700; font-family:-apple-system,"Hiragino Sans",sans-serif; white-space:nowrap; }
.mm-ar-arrow-left { left:10px; }
.mm-ar-arrow-right { right:10px; }
.mm-ar-error { position:absolute; left:10px; right:10px; bottom:10px; background:rgba(200,30,30,.94); color:#fff; padding:10px 12px; border-radius:10px; font-size:12.5px; line-height:1.6; font-family:-apple-system,"Hiragino Sans",sans-serif; white-space:pre-line; }
`;
  document.head.appendChild(style);
}

// 簡易な人影シルエット（頭+胴体・顔検出等は一切行わないダミー図形）
const SILHOUETTE_SVG = `
<svg class="mm-ar-silhouette-svg" viewBox="0 0 100 200" preserveAspectRatio="xMidYMax meet">
  <circle cx="50" cy="28" r="24" />
  <path d="M50 56 C22 56 14 82 14 112 L14 188 C14 195 20 200 27 200 L38 200 C43 200 45 195 45 188 L45 138 L55 138 L55 188 C55 195 57 200 62 200 L73 200 C80 200 86 195 86 188 L86 112 C86 82 78 56 50 56 Z" />
</svg>`;

/**
 * ARコンポーネントをel配下にマウントする。
 * @param {HTMLElement} el マウント先のコンテナ要素（position:relativeを内部で付与）
 * @param {{fovDeg?: number}} [config]
 * @returns {{start:(opts?:{camera?:boolean})=>Promise<{camera:string, orientation:string}>, stop:()=>void, setMe:(lat:number,lng:number,floor?:number)=>void, setPartner:(lat:number,lng:number,floor?:number,name?:string)=>void}}
 */
export function mountAR(el, config = {}) {
  if (!el) throw new Error('mountAR(el): el が必要です');
  const fovDeg = config.fovDeg || DEFAULT_FOV_DEGREES;

  injectStyleOnce();
  el.classList.add('mm-ar-root');
  el.innerHTML = `
    <video class="mm-ar-video" autoplay muted playsinline></video>
    <div class="mm-ar-fallback-bg" hidden>カメラ映像はありません（デバッグ表示のみ）</div>
    <div class="mm-ar-overlay">
      <div class="mm-ar-person" hidden>
        <div class="mm-ar-floor"></div>
        ${SILHOUETTE_SVG}
        <div class="mm-ar-name"></div>
        <div class="mm-ar-distance"></div>
      </div>
      <div class="mm-ar-arrow mm-ar-arrow-left" hidden></div>
      <div class="mm-ar-arrow mm-ar-arrow-right" hidden></div>
    </div>
    <div class="mm-ar-error" hidden></div>
  `;

  const videoEl = el.querySelector('.mm-ar-video');
  const fallbackBgEl = el.querySelector('.mm-ar-fallback-bg');
  const personEl = el.querySelector('.mm-ar-person');
  const silhouetteSvg = el.querySelector('.mm-ar-silhouette-svg');
  const nameEl = el.querySelector('.mm-ar-name');
  const distanceEl = el.querySelector('.mm-ar-distance');
  const floorEl = el.querySelector('.mm-ar-floor');
  const arrowLeftEl = el.querySelector('.mm-ar-arrow-left');
  const arrowRightEl = el.querySelector('.mm-ar-arrow-right');
  const errorEl = el.querySelector('.mm-ar-error');

  /** @type {{lat:number,lng:number,floor:number}|null} */
  let me = null;
  /** @type {{lat:number,lng:number,floor:number,name:string}|null} */
  let partner = null;

  let heading = 0; // コンパス方位(度, 0=北・時計回り)
  let betaDeg = BETA_NEUTRAL_DEG; // 前後の傾き

  let stream = null;
  let rafId = null;
  let orientationEventName = null; // 実際に購読したイベント名（テスト/デバッグ用に保持するだけ）
  let stopped = true;

  function pickOrientationEventName() {
    // Android Chromeは絶対方位が取れる deviceorientationabsolute を優先する。
    // iOS Safariにはこのイベントが無いため deviceorientation にフォールバックする。
    return 'ondeviceorientationabsolute' in window
      ? 'deviceorientationabsolute'
      : 'deviceorientation';
  }

  function handleOrientation(e) {
    let hdg = null;
    if (typeof e.webkitCompassHeading === 'number' && !Number.isNaN(e.webkitCompassHeading)) {
      // iOS Safari独自プロパティ。既に「0=北・時計回り」のコンパス方位そのものなので変換不要。
      hdg = e.webkitCompassHeading;
    } else if (typeof e.alpha === 'number') {
      // 標準のalphaは反時計回りのため、コンパス表記(時計回り)に変換する。
      // 注: deviceorientation(絶対値でない相対alpha)しか取れない端末では基準がズレる可能性がある（既知の限界）。
      hdg = (360 - e.alpha) % 360;
    }
    if (hdg != null) heading = hdg;
    if (typeof e.beta === 'number') betaDeg = e.beta;
    render();
  }

  async function requestOrientationPermission() {
    const DOE = window.DeviceOrientationEvent;
    if (DOE && typeof DOE.requestPermission === 'function') {
      // iOS 13+ Safari: ユーザー操作(クリック)から呼ばれるstart()の中で直接叩く必要がある。
      try {
        const result = await DOE.requestPermission();
        // iOS Safariの仕様上は 'granted' / 'denied' のいずれかしか返らない。
        // 一部のChromium実装は将来対応の暫定値として 'prompt' 等を返すことがあるため、
        // 明示的に 'denied' が返った場合のみ拒否として扱う（実機iOSでの'denied'応答は未検証・仕様書ベース）。
        return result === 'denied' ? 'denied' : 'granted';
      } catch {
        return 'denied';
      }
    }
    return 'unnecessary'; // iOS以外は許可APIそのものが無い
  }

  function attachOrientationListener() {
    if (orientationEventName) return; // 二重登録防止（冪等）
    orientationEventName = pickOrientationEventName();
    window.addEventListener(orientationEventName, handleOrientation, true);
  }

  function detachOrientationListener() {
    if (orientationEventName) {
      window.removeEventListener(orientationEventName, handleOrientation, true);
      orientationEventName = null;
    }
  }

  async function setupCamera() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      showFallback(true);
      return 'unavailable';
    }
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment' },
        audio: false,
      });
      videoEl.srcObject = stream;
      await videoEl.play().catch(() => {});
      showFallback(false);
      return 'granted';
    } catch {
      showFallback(true);
      return 'denied';
    }
  }

  function showFallback(show) {
    fallbackBgEl.hidden = !show;
    videoEl.hidden = show;
  }

  function showError(message, { append = false } = {}) {
    errorEl.hidden = false;
    errorEl.textContent = append && !errorEl.hidden && errorEl.textContent
      ? `${errorEl.textContent}\n${message}`
      : message;
  }

  function clearError() {
    errorEl.hidden = true;
    errorEl.textContent = '';
  }

  function render() {
    if (!me || !partner) return;

    const width = el.clientWidth || 390;
    const height = el.clientHeight || 640;

    const brng = bearingDegrees(me.lat, me.lng, partner.lat, partner.lng);
    const dist = distanceMeters(me.lat, me.lng, partner.lat, partner.lng);
    const rel = normalizeAngleDiff(heading, brng); // 正=相手は右, 負=相手は左
    const halfFov = fovDeg / 2;

    if (Math.abs(rel) <= halfFov) {
      arrowLeftEl.hidden = true;
      arrowRightEl.hidden = true;
      personEl.hidden = false;

      const xRatio = clamp(rel / halfFov, -1, 1);
      const x = width / 2 + xRatio * width * HORIZONTAL_MARGIN_RATIO;
      const vOffset = clamp(
        (betaDeg - BETA_NEUTRAL_DEG) * VERTICAL_PX_PER_DEG,
        -VERTICAL_OFFSET_CLAMP,
        VERTICAL_OFFSET_CLAMP
      );
      const y = height * BASE_Y_RATIO + vOffset;

      personEl.style.left = `${x}px`;
      personEl.style.top = `${y}px`;

      // 距離に応じてシルエットの大きさを変える（実際の透視投影ではない簡易な概算スケーリング）
      const sizePx = clamp(SIZE_SCALE_CONST / Math.max(dist, 1), SIZE_MIN_PX, SIZE_MAX_PX);
      silhouetteSvg.style.width = `${sizePx}px`;
      silhouetteSvg.style.height = `${sizePx * 2}px`;

      nameEl.textContent = partner.name || '相手';
      distanceEl.textContent = formatDistance(dist);

      const floorInfo = floorIndicatorText(me.floor, partner.floor);
      if (floorInfo) {
        floorEl.hidden = false;
        floorEl.textContent = floorInfo.text;
      } else {
        floorEl.hidden = true;
      }
    } else {
      personEl.hidden = true;
      const label = `${formatDistance(dist)}・${partner.name || '相手'}`;
      if (rel > 0) {
        arrowRightEl.hidden = false;
        arrowRightEl.textContent = `→ 右に振り向いて（${label}）`;
        arrowLeftEl.hidden = true;
      } else {
        arrowLeftEl.hidden = false;
        arrowLeftEl.textContent = `← 左に振り向いて（${label}）`;
        arrowRightEl.hidden = true;
      }
    }
  }

  function startRenderLoop() {
    if (rafId != null) return;
    const loop = () => {
      render();
      rafId = requestAnimationFrame(loop);
    };
    rafId = requestAnimationFrame(loop);
  }

  function stopRenderLoop() {
    if (rafId != null) cancelAnimationFrame(rafId);
    rafId = null;
  }

  async function start(opts = {}) {
    const useCamera = opts.camera !== false;
    stopped = false;
    clearError();

    const orientationStatus = await requestOrientationPermission();
    if (orientationStatus === 'denied') {
      showError(
        '向きセンサーの利用が許可されませんでした。設定 > Safari > モーションと画面の向きへのアクセス から許可してください。'
      );
    } else {
      attachOrientationListener();
    }

    let cameraStatus = 'skipped';
    if (useCamera) {
      cameraStatus = await setupCamera();
      if (cameraStatus === 'denied') {
        showError('カメラの利用が許可されませんでした。設定からカメラへのアクセスを許可してください。', {
          append: true,
        });
      } else if (cameraStatus === 'unavailable') {
        showError('この端末・ブラウザではカメラが利用できません。', { append: true });
      }
    } else {
      showFallback(true);
    }

    startRenderLoop();
    render();
    return { camera: cameraStatus, orientation: orientationStatus };
  }

  function stop() {
    if (stopped) return;
    stopped = true;
    stopRenderLoop();
    detachOrientationListener();
    if (stream) {
      stream.getTracks().forEach((t) => t.stop());
      stream = null;
    }
    videoEl.srcObject = null;
    personEl.hidden = true;
    arrowLeftEl.hidden = true;
    arrowRightEl.hidden = true;
  }

  function setMe(lat, lng, floor = 1) {
    me = { lat, lng, floor };
    render();
  }

  function setPartner(lat, lng, floor = 1, name = '相手') {
    partner = { lat, lng, floor, name };
    render();
  }

  return { start, stop, setMe, setPartner };
}
