import XCTest

/// 渋谷マチマチのApp Store用スクリーンショット。デモモード(模擬の相手)でたどるので、
/// 実際の位置・招待リンク・秘密情報は写らない。保存先は環境変数 SHOTS_DIR
/// (xcodebuild には TEST_RUNNER_SHOTS_DIR として渡す)。
final class StoreShotsUITests: XCTestCase {
    private let bundleId = "jp.co.ryoseiworld.shibuyamachimachi"
    private let nickname = ProcessInfo.processInfo.environment["SHOTS_NICKNAME"] ?? "りょうせい"
    private var outDir: String { ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? NSTemporaryDirectory() }

    override func setUp() {
        continueAfterFailure = false
    }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
        XCTAssertNoThrow(try data.write(to: url))
    }

    /// 要素が画面内に来るまで上にスワイプする(最大 maxSwipes 回)
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var n = 0
        while (!element.exists || !element.isHittable) && n < maxSwipes {
            app.swipeUp(velocity: .slow)
            n += 1
        }
    }

    /// 全画面表示(AR・高画質)の「閉じる」のうち、いま押せるものを押す
    private func closeOverlay(in app: XCUIApplication) {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", "閉じる")).allElementsBoundByIndex
        if let visible = buttons.first(where: { $0.isHittable }) { visible.tap() }
        sleep(1)
    }

    func testStoreScreenshots() throws {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        if ProcessInfo.processInfo.environment["SHOTS_ATTACH"] == "1" {
            app.activate() // 既に起動済みのアプリをそのまま使う(simctl launch --console でログを取るとき)
        } else {
            app.terminate()
            app.launch()
        }

        // 1. 作成画面(ニックネームを入れた状態)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(nickname)
        app.staticTexts["渋谷駅から半径1.5km限定の1対1待ち合わせ"].tap() // キーボードを閉じる
        sleep(1)
        save("01_create")

        // 2. デモで試す → 招待リンク画面
        app.buttons["デモで試す（1台で体験）"].tap()
        XCTAssertTrue(app.staticTexts["招待リンクを送ってください"].waitForExistence(timeout: 15))
        sleep(1)
        save("02_invite")

        // 3. 相手(すず)が参加 → 承認
        let approve = app.buttons["この人と位置を共有する"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        sleep(1)
        save("03_approve")
        approve.tap()

        // 4. 待ち合わせ画面(距離・矢印)。相手が少し近づくまで待つ
        XCTAssertTrue(app.buttons["会えた！"].waitForExistence(timeout: 15))
        sleep(14)
        save("04_meet")

        // 5. 3D渋谷
        let arButton = app.buttons["ARで探す"]
        scrollTo(arButton, in: app)
        sleep(6)
        save("05_3d")

        // 6. 高画質で見る(PLATEAU LOD2)
        let hq = app.buttons["高画質で見る"]
        scrollTo(hq, in: app)
        hq.tap()
        sleep(25)
        save("06_hq")
        closeOverlay(in: app)

        // 7. 近くのお店(「今いる階」の枠が見えるところまで戻す)
        let floorLabel = app.staticTexts["今いる階"]
        var n = 0
        while (!floorLabel.exists || !floorLabel.isHittable) && n < 4 {
            app.swipeDown(velocity: .slow)
            n += 1
        }
        sleep(2)
        save("07_shops")

        // 8. AR(シミュレータにはカメラが無いので、確認用。ストアには使わない)
        scrollTo(arButton, in: app)
        arButton.tap()
        sleep(4)
        save("08_ar")
        closeOverlay(in: app)

        // 9. 会えた！(相手が20m以内・同じ階まで来たら)
        let judge = app.buttons["会えた！"]
        var tries = 0
        while !judge.isHittable && tries < 12 {
            app.swipeDown(velocity: .fast)
            tries += 1
        }
        sleep(3)
        judge.tap()
        sleep(2)
        save("09_found")
    }
}
