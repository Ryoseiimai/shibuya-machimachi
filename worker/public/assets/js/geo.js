// 座標・方位計算のユーティリティ。
// DOM/ブラウザAPIに一切依存しない純粋関数のみを置く（node:test でそのまま単体テストするため）。

const EARTH_RADIUS_M = 6371000; // 地球半径(m) 球体近似
const DEG2RAD = Math.PI / 180;
const RAD2DEG = 180 / Math.PI;

// AR部品が「視野内」とみなす水平画角(度)。スマホ背面カメラの一般的な画角に合わせた概算値。
export const DEFAULT_FOV_DEGREES = 60;

export function toRad(deg) {
  return deg * DEG2RAD;
}

export function toDeg(rad) {
  return rad * RAD2DEG;
}

export function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

// 2点間の距離(m) — Haversine公式
export function distanceMeters(lat1, lng1, lat2, lng2) {
  const phi1 = toRad(lat1);
  const phi2 = toRad(lat2);
  const dPhi = toRad(lat2 - lat1);
  const dLambda = toRad(lng2 - lng1);
  const a =
    Math.sin(dPhi / 2) ** 2 +
    Math.cos(phi1) * Math.cos(phi2) * Math.sin(dLambda / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return EARTH_RADIUS_M * c;
}

// 起点(lat1,lng1)から終点(lat2,lng2)を見た真方位(度, 0=北・時計回り)
export function bearingDegrees(lat1, lng1, lat2, lng2) {
  const phi1 = toRad(lat1);
  const phi2 = toRad(lat2);
  const dLambda = toRad(lng2 - lng1);
  const y = Math.sin(dLambda) * Math.cos(phi2);
  const x =
    Math.cos(phi1) * Math.sin(phi2) -
    Math.sin(phi1) * Math.cos(phi2) * Math.cos(dLambda);
  const theta = Math.atan2(y, x);
  return (toDeg(theta) + 360) % 360;
}

// 角度差 b-a を -180〜180 に正規化する。
// AR描画では「自分の向きheadingから見て相手の方位brngが何度ズレているか」に使う。
// 戻り値が正 = 相手は右側、負 = 相手は左側。
export function normalizeAngleDiff(a, b) {
  let diff = (b - a) % 360;
  if (diff > 180) diff -= 360;
  if (diff < -180) diff += 360;
  return diff;
}

// 起点(lat,lng)から方位bearingDeg・距離distMだけ進んだ地点の緯度経度を返す。
// Movable Type Scripts の定番公式に準拠。デモの「距離オフセット→座標」変換に使う。
export function destinationPoint(lat, lng, bearingDeg, distM) {
  const phi1 = toRad(lat);
  const lambda1 = toRad(lng);
  const theta = toRad(bearingDeg);
  const delta = distM / EARTH_RADIUS_M;
  const phi2 = Math.asin(
    Math.sin(phi1) * Math.cos(delta) +
      Math.cos(phi1) * Math.sin(delta) * Math.cos(theta)
  );
  const lambda2 =
    lambda1 +
    Math.atan2(
      Math.sin(theta) * Math.sin(delta) * Math.cos(phi1),
      Math.cos(delta) - Math.sin(phi1) * Math.sin(phi2)
    );
  return { lat: toDeg(phi2), lng: ((toDeg(lambda2) + 540) % 360) - 180 };
}

// 北方向・東方向のメートルオフセットから目的地の緯度経度を返す（デモ/デバッグ用の簡易ヘルパー）。
export function destinationFromOffset(lat, lng, northM, eastM) {
  const distM = Math.sqrt(northM * northM + eastM * eastM);
  if (distM === 0) return { lat, lng };
  const bearingDeg = (toDeg(Math.atan2(eastM, northM)) + 360) % 360;
  return destinationPoint(lat, lng, bearingDeg, distM);
}

// 距離の表示用フォーマット（例: 「あと120m」「あと1.2km」）
export function formatDistance(distM) {
  if (distM < 1000) return `あと${Math.round(distM)}m`;
  return `あと${(distM / 1000).toFixed(1)}km`;
}

// 階数表記。1,2,3.. は地上階、-1,-2.. は地下(B1,B2..) という前提（0階は無し）。
export function formatFloor(floor) {
  if (floor >= 1) return `${floor}F`;
  return `B${Math.abs(floor)}`;
}

// 自分の階と相手の階から、上下インジケータの文言を返す。同じ階ならnull。
// 例: 自分1F・相手3F → { dir:'up', text:'↑2階上' }
//     自分1F・相手B1  → { dir:'down', text:'↓B1' }
export function floorIndicatorText(myFloor, partnerFloor) {
  const diff = partnerFloor - myFloor;
  if (diff === 0) return null;
  if (diff > 0) return { dir: 'up', text: `↑${diff}階上` };
  return { dir: 'down', text: `↓${formatFloor(partnerFloor)}` };
}
