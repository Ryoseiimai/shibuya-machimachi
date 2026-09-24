// 実験的機能: Meta Quest Browser など WebXR(immersive-ar / immersive-vr) 対応端末向けの
// 「VRメガネで見る」最小three.jsシーン。
//
// 重要な注意（実装時点で実機検証できていない）:
// - 手元にQuest等の実機が無く、動作確認は一切できていない。
// - iPhone/Vision Pro(visionOS Safari) では対象外とし、ボタン自体を出さない（明示的にUA判定で除外）。
// - セッション開始時点の相対方位のみを反映して人影を1体置くだけの最小実装。
//   その後の実際の首振り(センサー追従)には対応していない（既知の限界）。
// - 他人の検出・顔認識などは一切行わない。方向の目印としてダミーの人型を置くだけ。

const THREE_VERSION = '0.169.0';
const THREE_BASE = `https://cdn.jsdelivr.net/npm/three@${THREE_VERSION}`;

function isDefinitelyUnsupportedPlatform() {
  const ua = (typeof navigator !== 'undefined' && navigator.userAgent) || '';
  // iPhone/iPad/Vision Pro(visionOS)は明示的に対象外にする
  return /iPhone|iPad|iPod|Vision Pro|VisionOS/i.test(ua);
}

/**
 * この端末でWebXRの没入セッションが使えそうか判定する。
 * @returns {Promise<'immersive-ar'|'immersive-vr'|null>}
 */
export async function isVrAvailable() {
  if (isDefinitelyUnsupportedPlatform()) return null;
  if (typeof navigator === 'undefined' || !('xr' in navigator) || !navigator.xr) return null;
  try {
    const arSupported = await navigator.xr.isSessionSupported('immersive-ar').catch(() => false);
    if (arSupported) return 'immersive-ar';
    const vrSupported = await navigator.xr.isSessionSupported('immersive-vr').catch(() => false);
    if (vrSupported) return 'immersive-vr';
    return null;
  } catch {
    return null;
  }
}

/**
 * 相手の相対方位・距離をもとに、その方向に人影を1体置くだけの最小WebXRシーンを開始する。
 * @param {HTMLElement} container ボタン/canvasを追加する要素
 * @param {'immersive-ar'|'immersive-vr'} mode
 * @param {number} relativeBearingDeg 自分の向きから見た相手の相対角(度, 正=右)
 * @param {number} distanceM 相手までの距離(m)
 */
export async function startVrScene(container, mode, relativeBearingDeg, distanceM) {
  const THREE = await import(/* webpackIgnore: true */ `${THREE_BASE}/build/three.module.js`);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(
    70,
    window.innerWidth / window.innerHeight,
    0.01,
    100
  );
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.xr.enabled = true;
  container.appendChild(renderer.domElement);

  scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 1.2));

  // 超簡易な人影(カプセル+球)。顔検出等は行わず、方角の目印として置くだけ。
  const group = new THREE.Group();
  const body = new THREE.Mesh(
    new THREE.CapsuleGeometry(0.2, 1.0, 4, 8),
    new THREE.MeshStandardMaterial({ color: 0x222233 })
  );
  body.position.y = 0.9;
  const head = new THREE.Mesh(
    new THREE.SphereGeometry(0.15, 16, 16),
    new THREE.MeshStandardMaterial({ color: 0x222233 })
  );
  head.position.y = 1.65;
  group.add(body, head);

  // 距離(m)をそのままシーン内メートルとして配置。方位はセッション開始時点の相対角のみ反映（追従はしない）。
  const clampedDist = Math.min(Math.max(distanceM, 1.5), 20);
  const rad = (relativeBearingDeg * Math.PI) / 180;
  group.position.set(Math.sin(rad) * clampedDist, 0, -Math.cos(rad) * clampedDist);
  scene.add(group);

  let button = null;
  try {
    const moduleName = mode === 'immersive-ar' ? 'ARButton' : 'VRButton';
    const mod = await import(
      /* webpackIgnore: true */ `${THREE_BASE}/examples/jsm/webxr/${moduleName}.js`
    );
    button = mod[moduleName].createButton(renderer, { requiredFeatures: [] });
    document.body.appendChild(button);
  } catch (err) {
    // ARButton/VRButton の読み込みに失敗しても、シーン自体は破棄してエラーを呼び出し元に伝える。
    renderer.dispose();
    container.removeChild(renderer.domElement);
    throw err;
  }

  renderer.setAnimationLoop(() => {
    renderer.render(scene, camera);
  });

  return {
    stop() {
      renderer.setAnimationLoop(null);
      renderer.dispose();
      if (renderer.domElement.parentNode) renderer.domElement.parentNode.removeChild(renderer.domElement);
      if (button && button.parentNode) button.parentNode.removeChild(button);
    },
  };
}
