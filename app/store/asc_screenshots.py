#!/usr/bin/env python3
"""App Store Connect にスクリーンショット(iPhone 6.9インチ枠)を入れる(ASC API)。

  python3 app/store/asc_screenshots.py <App Apple ID> <画像1.png> <画像2.png> ...

画像は指定した順に並ぶ。既存の同じ枠のスクリーンショットは先に消してから入れ直す(何度実行しても同じ結果)。
画像は app/store/shots/run.sh(シミュレータの実画面・デモモード)で撮ったもの。
"""
import hashlib
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import call  # noqa: E402

# 6.9インチ(1320x2868)は API では APP_IPHONE_67 の枠に入る(前例アプリと同じ)
DISPLAY_TYPE = "APP_IPHONE_67"
POLL_INTERVAL_S = 5
POLL_MAX = 60


def must(label, status, body):
    if status >= 300:
        raise SystemExit(f"{label}: HTTP {status} {str(body)[:600]}")
    return body


def screenshot_set_id(app_id):
    body = must("version", *call("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&filter[appStoreState]=PREPARE_FOR_SUBMISSION"))
    version_id = body["data"][0]["id"]
    body = must("localization", *call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?filter[locale]=ja"))
    loc_id = body["data"][0]["id"]
    body = must("sets", *call("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?filter[screenshotDisplayType]={DISPLAY_TYPE}"))
    if body["data"]:
        return body["data"][0]["id"]
    body = must("create set", *call("POST", "/v1/appScreenshotSets", {"data": {
        "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}}))
    return body["data"]["id"]


def upload_one(set_id, path):
    data = open(path, "rb").read()
    name = os.path.basename(path)
    body = must(f"reserve {name}", *call("POST", "/v1/appScreenshots", {"data": {
        "type": "appScreenshots", "attributes": {"fileName": name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}}))
    shot_id = body["data"]["id"]
    for op in body["data"]["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for h in op.get("requestHeaders", []):
            req.add_header(h["name"], h["value"])
        with urllib.request.urlopen(req, timeout=120) as r:
            if r.status >= 300:
                raise SystemExit(f"upload {name}: HTTP {r.status}")
    must(f"commit {name}", *call("PATCH", f"/v1/appScreenshots/{shot_id}", {"data": {
        "type": "appScreenshots", "id": shot_id,
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}))
    return shot_id


def main(app_id, paths):
    set_id = screenshot_set_id(app_id)
    body = must("existing", *call("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots"))
    for old in body["data"]:
        must("delete old", *call("DELETE", f"/v1/appScreenshots/{old['id']}"))
    ids = [upload_one(set_id, p) for p in paths]
    for _ in range(POLL_MAX):
        states = []
        for sid in ids:
            b = must("state", *call("GET", f"/v1/appScreenshots/{sid}"))
            states.append((b["data"]["attributes"].get("assetDeliveryState") or {}).get("state"))
        print("states:", states)
        if all(s == "COMPLETE" for s in states):
            break
        if any(s == "FAILED" for s in states):
            raise SystemExit("スクリーンショットの処理に失敗しました")
        time.sleep(POLL_INTERVAL_S)
    must("reorder", *call("PATCH", f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
                          {"data": [{"type": "appScreenshots", "id": i} for i in ids]}))
    print(f"スクリーンショット {len(ids)} 枚を登録しました(set {set_id})")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("usage: asc_screenshots.py <App Apple ID> <png>...")
    main(sys.argv[1], sys.argv[2:])
