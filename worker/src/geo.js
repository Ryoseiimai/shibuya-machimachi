/**
 * 純粋関数の地理計算ユーティリティ。
 * room.js / room-do.js とテスト(test/geo.test.js)の両方から読み込む。
 *
 * 出典: Ryoseiimai/gmaps-share-finder (worker/src/geo.js, MIT License) から
 * そのまま移植。ハバーサイン距離・方位角の実装に変更点なし。
 */

// メートル単位の距離(ハバーサイン)
export function distanceMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// from(lat1,lng1)から見たto(lat2,lng2)への方位角(0=北, 時計回り)
export function bearingDegrees(lat1, lng1, lat2, lng2) {
  const toRad = (d) => (d * Math.PI) / 180;
  const toDeg = (r) => (r * 180) / Math.PI;
  const y = Math.sin(toRad(lng2 - lng1)) * Math.cos(toRad(lat2));
  const x =
    Math.cos(toRad(lat1)) * Math.sin(toRad(lat2)) -
    Math.sin(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.cos(toRad(lng2 - lng1));
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

// 中心点(centerLat,centerLng)から半径radiusM以内にあるか
export function isWithinRadius(lat, lng, centerLat, centerLng, radiusM) {
  return distanceMeters(lat, lng, centerLat, centerLng) <= radiusM;
}

export const MIN_LATITUDE = -90;
export const MAX_LATITUDE = 90;
export const MIN_LONGITUDE = -180;
export const MAX_LONGITUDE = 180;

// 緯度経度として有効な範囲内の有限数かどうか(NaN・±Infinity・地球上に存在しない値を弾く。
// M4セキュリティ対応: クライアントから届くlat/lngをroom.jsのupdateLocation()で使う)。
export function isValidCoordinate(lat, lng) {
  return (
    typeof lat === "number" &&
    Number.isFinite(lat) &&
    lat >= MIN_LATITUDE &&
    lat <= MAX_LATITUDE &&
    typeof lng === "number" &&
    Number.isFinite(lng) &&
    lng >= MIN_LONGITUDE &&
    lng <= MAX_LONGITUDE
  );
}
