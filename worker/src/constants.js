/**
 * マジックナンバーを集約する定数ファイル。
 * room.js / room-do.js / html.js から読み込む。
 */

// 渋谷駅の座標(度)。エリア制限の中心点。
export const SHIBUYA_STATION = { lat: 35.658, lng: 139.7016 };

// 渋谷エリアとみなす半径(メートル)。この外側では自分の位置を送らない。
export const SHIBUYA_RADIUS_M = 1500;

// 1部屋に入れる人数の上限(1対1待ち合わせなので2人固定)。
export const MAX_PARTICIPANTS = 2;

// 部屋の自動終了までの時間(ミリ秒)。経過後は位置データを含め全て削除する。
export const ROOM_TTL_MS = 3 * 60 * 60 * 1000; // 3時間

// 「会えた？」判定を試みてよい距離のしきい値(メートル)。
export const MEET_DISTANCE_M = 20;

// 1部屋あたりのJev API呼び出し回数の上限。超えたら距離だけの判定にフォールバックする。
export const MAX_JUDGE_CALLS = 10;

// 位置情報が「古い」とみなされるまでの時間(ミリ秒)。UIの最終更新表示や判定の可否に使う。
export const LOCATION_STALE_MS = 2 * 60 * 1000; // 2分

// B5〜10Fのフロア一覧。配列のindexをそのまま高さの順序として扱う(floors.js参照)。
export const FLOORS = [
  "B5", "B4", "B3", "B2", "B1",
  "1F", "2F", "3F", "4F", "5F", "6F", "7F", "8F", "9F", "10F",
];
