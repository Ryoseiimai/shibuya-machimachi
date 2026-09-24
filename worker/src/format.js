export function formatRelativeTime(timestamp, now = Date.now()) {
  const timestampMs = typeof timestamp === "number" ? timestamp : Date.parse(timestamp);
  if (!Number.isFinite(timestampMs) || !Number.isFinite(now)) return "不明";

  const elapsedSeconds = Math.floor(Math.max(0, now - timestampMs) / 1000);
  if (elapsedSeconds < 60) return `${elapsedSeconds}秒前`;

  const elapsedMinutes = Math.floor(elapsedSeconds / 60);
  if (elapsedMinutes < 60) return `${elapsedMinutes}分前`;

  const elapsedHours = Math.floor(elapsedMinutes / 60);
  if (elapsedHours < 24) return `${elapsedHours}時間前`;

  return `${Math.floor(elapsedHours / 24)}日前`;
}
