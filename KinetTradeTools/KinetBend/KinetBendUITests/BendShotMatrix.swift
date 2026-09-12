import XCTest

/// 截图矩阵:5 模式 × 4 语言 = 20 张(6.9" 1320×2868)+ 每组合一条本地化断言
/// 产物落 /tmp/xbend/shot-{mode}-{lang}.png
final class BendShotMatrix: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(mode: String, language: String?) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-KinetBendMode", mode]
        if let language { args += ["-AppleLanguages", "(\(language))"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, mode: String, lang: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: "/tmp/xbend", withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "/tmp/xbend/shot-\(mode)-\(lang).png"))
    }

    private func shootLanguage(_ lang: String?, label: String, check: String) throws {
        let langKey = lang ?? "en"
        for mode in ["stubup", "offset", "saddle3", "saddle4", "kick"] {
            let app = launch(mode: mode, language: lang)
            let pred = NSPredicate(format: "label CONTAINS %@", check)
            let ok = app.staticTexts.matching(pred).firstMatch.waitForExistence(timeout: 8)
            XCTAssertTrue(ok, "[\(langKey)] \(mode): 未找到 '\(check)'")
            shot(app, mode: mode, lang: langKey)
            app.terminate()
        }
    }

    func testShotEn() throws { try shootLanguage(nil, label: "en", check: "Height (in)") }
    func testShotZhHans() throws { try shootLanguage("zh-Hans", label: "zh-Hans", check: "高度(英寸)") }
    func testShotZhHant() throws { try shootLanguage("zh-Hant", label: "zh-Hant", check: "高度(英寸)") }
    func testShotJa() throws { try shootLanguage("ja", label: "ja", check: "高さ(インチ)") }
}
