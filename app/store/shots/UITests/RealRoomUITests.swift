import XCTest

/// 本番Workerとの実通信の確認(ストア用の撮影ではない)。アプリで待ち合わせを作り、招待リンクを
/// SHOTS_DIR/invite_url.txt に書き出す。別プロセス(ブラウザのゲスト)が参加したら承認し、
/// 距離が表示されるまで待つ。シミュレータの位置は simctl location で渋谷駅前に固定しておくこと。
final class RealRoomUITests: XCTestCase {
    private let bundleId = "jp.co.ryoseiworld.shibuyamachimachi"
    private var outDir: String { ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? NSTemporaryDirectory() }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    }

    func testRealRoomWithBrowserGuest() throws {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        app.terminate()
        app.launch()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("host-e2e")
        app.buttons["待ち合わせを作る"].tap()
        // 位置情報の許可ダイアログ(初回のみ)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["アプリの使用中は許可", "Allow While Using App"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 4) { b.tap(); break }
        }
        XCTAssertTrue(app.staticTexts["招待リンクを送ってください"].waitForExistence(timeout: 20))
        let invite = app.textFields.firstMatch.value as? String ?? ""
        XCTAssertTrue(invite.hasPrefix("https://shibuya-machimachi.kaeru3160.workers.dev/r/"), invite)
        try invite.write(toFile: outDir + "/invite_url.txt", atomically: true, encoding: .utf8)
        save("real_01_invite")
        let approve = app.buttons["この人と位置を共有する"]
        XCTAssertTrue(approve.waitForExistence(timeout: 90), "ブラウザのゲストが参加しない")
        save("real_02_approve")
        approve.tap()
        let meters = app.staticTexts["m"]
        XCTAssertTrue(app.buttons["会えた！"].waitForExistence(timeout: 20))
        sleep(15)
        save("real_03_meet")
        _ = meters
        app.buttons["共有をやめる"].tap()
        let ok = app.alerts.buttons["OK"]
        if ok.waitForExistence(timeout: 5) { ok.tap() }
        sleep(2)
        save("real_04_stopped")
    }
}
