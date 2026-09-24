/**
 * TypeSafe AI Jev(systemone)への「会えた？」判定呼び出し。
 * 仕様の出典: ~/.claude/skills/jev-judge/SKILL.md と scripts/judge.py の _build_payload()
 * (2026-09-22 https://docs.typesafe.ai/api.md 実測反映)。
 *   POST https://api.typesafe.ai/v1/systemone
 *   body: {state, model:"jev-latest", questions:{id:{type:"noul", instructions}}}
 *   resp: {answers:{id:{type:"noul", noul: 0.0〜1.0}}}
 *
 * 意図的な簡略化: Jevは推論理由の文章を返さない仕様(judge.pyと同じ)なので、
 * reason_shortに相当するフィールドはそもそも要求しない。
 * 送るcontextには座標・ニックネームを含めない(第三者APIに渡す情報を最小化する設計。
 * 距離(m)・同階かどうか・経過時間・位置精度・更新の新しさ・両者の自己申告の有無だけを渡す)。
 */
import { MEET_DISTANCE_M } from "./constants.js";

export const JEV_API_ENDPOINT = "https://api.typesafe.ai/v1/systemone";
export const JEV_MODEL = "jev-latest";
// 判定基準を明示する: 距離がGPS精度の範囲内・同じ階・両者の自己申告が揃っていれば確度は高い。
// 逆に距離が離れている/階が違う/位置情報が古い/自己申告が片方だけなら確度を下げる。
export const JEV_QUESTION =
  "この2人は今、渋谷で実際に合流できた(会えた)と言えるか。" +
  "距離がGPS精度の範囲内に収まっていて同じ階にいて、かつ両者が「会えた」ボタンを近い時刻に押して" +
  "自己申告していれば、会えた確度は高いと判断してよい。逆に距離が離れている、階が違う、" +
  "位置情報の更新が古い、自己申告が片方だけ(または無い)場合は確度を下げること。";

function formatSecondsAgo(seconds) {
  if (!Number.isFinite(seconds)) return "不明";
  return `約${Math.max(0, Math.round(seconds))}秒前`;
}

function formatAccuracy(accuracyM) {
  if (!Number.isFinite(accuracyM)) return "不明";
  return `約${Math.round(accuracyM)}m`;
}

export function buildMeetContext({
  distance_m,
  floorMatch,
  waitingMinutes,
  hostAccuracy_m = null,
  guestAccuracy_m = null,
  hostUpdatedSecondsAgo = null,
  guestUpdatedSecondsAgo = null,
  bothPressedRecently = false,
}) {
  const minutes = Number.isFinite(waitingMinutes) ? Math.max(0, Math.round(waitingMinutes)) : 0;
  return (
    `渋谷での1対1待ち合わせアプリ。現在の推定距離は約${distance_m}m。` +
    `同じ階にいる: ${floorMatch ? "はい" : "いいえ"}。作成からの経過時間は約${minutes}分。` +
    `Aさんの位置精度: ${formatAccuracy(hostAccuracy_m)}。Bさんの位置精度: ${formatAccuracy(guestAccuracy_m)}。` +
    `Aさんの位置更新: ${formatSecondsAgo(hostUpdatedSecondsAgo)}。Bさんの位置更新: ${formatSecondsAgo(guestUpdatedSecondsAgo)}。` +
    `両者が60秒以内に「会えた」ボタンを押した: ${bothPressedRecently ? "はい" : "いいえ"}。`
  );
}

export function buildJevPayload(stateText, instructions = JEV_QUESTION) {
  return {
    state: stateText,
    model: JEV_MODEL,
    questions: { met: { type: "noul", instructions } },
  };
}

export async function callJev(apiKey, stateText, fetchImpl = fetch) {
  const payload = buildJevPayload(stateText);
  const res = await fetchImpl(JEV_API_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Jev API error ${res.status}: ${text.slice(0, 300)}`);
  }
  const data = await res.json();
  const answer = data?.answers?.met;
  if (!answer || answer.type !== "noul" || typeof answer.noul !== "number") {
    throw new Error("Jev APIの応答形式が不正です");
  }
  return { found: answer.noul >= 0.5, probability: answer.noul, source: "jev" };
}

// APIキー未設定、または1部屋の呼び出し上限に達したときのフォールバック。
// canAttemptJudge()がすでに「20m以内・同じ階」を確認した後にしか呼ばれない前提だが、
// 関数単体でも正しく動くように条件を再度見る。
export function distanceOnlyJudge({ distance_m, floorMatch }) {
  return {
    found: !!floorMatch && distance_m <= MEET_DISTANCE_M,
    probability: null,
    source: "distance_only",
  };
}
