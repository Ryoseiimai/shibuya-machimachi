#!/usr/bin/env python3
"""App Store Connect に掲載情報を入れる(ASC API)。何度実行しても同じ状態になる。

  python3 app/store/asc_metadata.py <App Apple ID>

入れるもの: 年齢制限の質問票 / カテゴリ / サブタイトル・プライバシーポリシーURL / 第三者コンテンツ申告 /
説明文・キーワード・プロモーションテキスト・サポートURL / 著作権 / App Review 情報(連絡先・メモ) /
価格(無料) / 配信地域。
鍵は ~/.appstoreconnect(asc.py 参照)、App Review の連絡先は ~/.appstoreconnect/review_contact.json
(リポジトリには置かない)から読む。
意図的な簡略化: 日本語(ja)の掲載情報だけを扱う。英語などを足すときは metadata.json に言語を増やし、
appInfoLocalizations / appStoreVersionLocalizations を POST する処理をここに足すのが入口。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import call  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
META = json.load(open(os.path.join(HERE, "metadata.json"), encoding="utf-8"))
CONTACT_PATH = os.path.expanduser("~/.appstoreconnect/review_contact.json")
PRICE_TERRITORY = "JPN"

# 年齢制限: 暴力・性的表現・ギャンブル・チャット・UGC・無制限Webアクセスなどいずれも無し(4+)。
AGE_RATING = {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "advertising": False,
    "ageAssurance": False,
    "gambling": False,
    "healthOrWellnessTopics": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "socialMedia": False,
    "socialMediaAgeRestricted": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "ageRatingOverrideV2": "NONE",
    "koreaAgeRatingOverride": "NONE",
}


def ok(label, status, body):
    if status >= 300:
        raise SystemExit(f"{label}: HTTP {status} {json.dumps(body, ensure_ascii=False)[:800]}")
    print(f"{label}: OK ({status})")
    return body


def first(path):
    status, body = call("GET", path)
    ok(f"GET {path.split('?')[0]}", status, body)
    data = body.get("data")
    return data[0] if isinstance(data, list) and data else data


def main(app_id):
    app_info = first(f"/v1/apps/{app_id}/appInfos")
    info_id = app_info["id"]

    status, body = call("PATCH", f"/v1/ageRatingDeclarations/{info_id}",
                        {"data": {"type": "ageRatingDeclarations", "id": info_id, "attributes": AGE_RATING}})
    ok("年齢制限", status, body)

    rel = {
        "primaryCategory": {"data": {"type": "appCategories", "id": META["app"]["primaryCategory"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": META["app"]["secondaryCategory"]}},
    }
    status, body = call("PATCH", f"/v1/appInfos/{info_id}", {"data": {"type": "appInfos", "id": info_id, "relationships": rel}})
    ok("カテゴリ", status, body)

    ja = META["ja"]
    loc = first(f"/v1/appInfos/{info_id}/appInfoLocalizations?filter[locale]=ja")
    attrs = {"name": META["app"]["name"], "subtitle": ja["subtitle"], "privacyPolicyUrl": ja["privacyPolicyUrl"]}
    status, body = call("PATCH", f"/v1/appInfoLocalizations/{loc['id']}",
                        {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": attrs}})
    ok("名前・サブタイトル・プライバシーポリシーURL", status, body)

    status, body = call("PATCH", f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {
        "contentRightsDeclaration": META["app"]["contentRightsDeclaration"]}}})
    ok("第三者コンテンツの申告", status, body)

    version = first(f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&filter[appStoreState]=PREPARE_FOR_SUBMISSION")
    version_id = version["id"]
    status, body = call("PATCH", f"/v1/appStoreVersions/{version_id}", {"data": {
        "type": "appStoreVersions", "id": version_id, "attributes": {"copyright": META["app"]["copyright"]}}})
    ok("著作権", status, body)

    vloc = first(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?filter[locale]=ja")
    vattrs = {k: ja[k] for k in ("description", "keywords", "promotionalText", "supportUrl", "marketingUrl")}
    status, body = call("PATCH", f"/v1/appStoreVersionLocalizations/{vloc['id']}",
                        {"data": {"type": "appStoreVersionLocalizations", "id": vloc["id"], "attributes": vattrs}})
    ok("説明文・キーワード・URL", status, body)

    contact = json.load(open(CONTACT_PATH, encoding="utf-8"))
    review_attrs = dict(contact, demoAccountRequired=False, notes=META["reviewNotes"])
    status, body = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    if status == 200 and body.get("data"):
        rid = body["data"]["id"]
        status, body = call("PATCH", f"/v1/appStoreReviewDetails/{rid}",
                            {"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": review_attrs}})
    else:
        status, body = call("POST", "/v1/appStoreReviewDetails", {"data": {
            "type": "appStoreReviewDetails", "attributes": review_attrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    ok("App Review 情報(連絡先・メモ)", status, body)

    set_free_price(app_id)
    set_availability(app_id)
    print("掲載情報の反映が完了しました。version:", version_id)


def set_free_price(app_id):
    status, body = call("GET", f"/v1/apps/{app_id}/appPricePoints?filter[territory]={PRICE_TERRITORY}&limit=200")
    ok("価格ポイント取得", status, body)
    free = [p for p in body["data"] if float(p["attributes"]["customerPrice"]) == 0.0]
    if not free:
        raise SystemExit("無料の価格ポイントが見つかりません")
    payload = {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": PRICE_TERRITORY}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${price1}"}]},
            },
        },
        "included": [{
            "type": "appPrices", "id": "${price1}",
            "attributes": {"startDate": None},
            "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free[0]["id"]}}},
        }],
    }
    status, body = call("POST", "/v1/appPriceSchedules", payload)
    ok("価格(無料)", status, body)


def set_availability(app_id):
    status, body = call("GET", f"/v1/apps/{app_id}/appAvailabilityV2")
    if status == 200 and body.get("data"):
        print("配信地域: 設定済みのため変更しません")
        return
    status, terr = call("GET", "/v1/territories?limit=200")
    ok("地域一覧", status, terr)
    ids = [t["id"] for t in terr["data"]]
    included = [{
        "type": "territoryAvailabilities", "id": f"${{{tid}}}",
        "attributes": {"available": True},
        "relationships": {"territory": {"data": {"type": "territories", "id": tid}}},
    } for tid in ids]
    payload = {
        "data": {
            "type": "appAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{tid}}}"} for tid in ids]},
            },
        },
        "included": included,
    }
    status, body = call("POST", "/v2/appAvailabilities", payload)
    ok(f"配信地域({len(ids)}地域)", status, body)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: asc_metadata.py <App Apple ID>")
    main(sys.argv[1])
