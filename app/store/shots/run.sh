#!/usr/bin/env bash
# App Store用スクリーンショットを撮る(シミュレータの実画面。デモモードでたどるので秘密・実位置は写らない)。
#   使い方: app/store/shots/run.sh <シミュレータUDID> <保存先ディレクトリ>
#   前提: 本体アプリをそのシミュレータにインストール済み(app/ios で xcodebuild → simctl install)
# 意図的な簡略化: 撮影する画面の順番はUIテスト(UITests/StoreShotsUITests.swift)に直書き。
#   画面構成を変えたらUIテスト側のボタン名・待ち時間も合わせて直すこと。
set -euo pipefail
UDID="$1"
OUT="$2"
cd "$(dirname "$0")"
xcodegen generate >/dev/null
mkdir -p "$OUT"
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
TEST_RUNNER_SHOTS_DIR="$OUT" xcodebuild test -project Shots.xcodeproj -scheme Shots \
  -destination "platform=iOS Simulator,id=${UDID}" -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  -only-testing:ShotsUITests/StoreShotsUITests
