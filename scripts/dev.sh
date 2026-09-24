#!/bin/bash
# 開発モード: Googleアカウント・Cloudflareアカウントなしでブラウザから確認できるようにする。
# wrangler dev をローカルのみ(--local, Miniflare)で起動してブラウザで開く。
# 実行: bash scripts/dev.sh (または `npm run dev` / `make dev`)
# 停止: Ctrl+C
# 2つのブラウザタブ(または閲覧モード)で同じURLを開けば、A/B 2人分を1台のPCで再現できる。
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8787}"
URL="http://127.0.0.1:${PORT}"

if [ ! -d worker/node_modules ]; then
  echo "==> worker/node_modules がないため npm install します(初回のみ)"
  (cd worker && npm install)
fi

echo "==> wrangler dev をローカルのみで起動します(実際のCloudflareアカウントには繋ぎません): ${URL}"
(cd worker && npx wrangler dev --port "${PORT}" --local) &
WRANGLER_PID=$!

cleanup() {
  echo "==> 停止処理中..."
  kill "${WRANGLER_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo -n "==> 起動待ち"
READY=0
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "${URL}/" 2>/dev/null; then
    READY=1
    break
  fi
  echo -n "."
  sleep 1
done
echo ""
if [ "${READY}" != "1" ]; then
  echo "wrangler dev の起動を確認できませんでした。上のログを確認してください。" >&2
  exit 1
fi

echo "==> 画面のURL: ${URL}/"
echo "==> 2人分を1台で試すには、このURLをタブをもう1つ開いて両方で操作してください。"
if command -v open >/dev/null 2>&1; then
  open "${URL}/"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${URL}/"
else
  echo "手動でブラウザからこのURLを開いてください: ${URL}/"
fi

echo "==> 開発サーバー稼働中。終了するには Ctrl+C"
wait "${WRANGLER_PID}"
