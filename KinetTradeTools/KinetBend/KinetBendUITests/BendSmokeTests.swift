import XCTest

/// 冒烟矩阵:五计算器跑数(en)+ 四语切换断言
/// 每个用例独立 launch,语言经 -AppleLanguages 注入;截图落 /tmp/xbend/
final class BendSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(mode: String? = nil, height: Double? = nil, angle: Double? = nil, language: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args: [String] = []
        if let mode { args += ["-KinetBendMode", mode] }
        if let height { args += ["-KinetBendHeight", String(height)] }
        if let angle { args += ["-KinetBendAngle", String(angle)] }
        if let language { args += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ja" ? "ja_JP" : "zh_CN"] }
        app.launchArguments = args
        app.launch()
        return app
    }

    private func assertText(_ app: XCUIApplication, _ contains: String, file: StaticString = #filePath, line: UInt = #line) {
        let pred = NSPredicate(format: "label CONTAINS %@", contains)
        let matched = app.staticTexts.matching(pred).firstMatch
        XCTAssertTrue(matched.waitForExistence(timeout: 8), "未找到文本: \(contains)", file: file, line: line)
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: "/tmp/xbend", withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "/tmp/xbend/\(name).png"))
    }

    // MARK: - 五计算器跑数(英语基线,黄金值)

    func test1StubUpEn() throws {
        let app = launch()
        assertText(app, "Take-up (deduct)")
        assertText(app, "Mark 1 (to arrow)")
        assertText(app, "12\"") // mark2 = height 12
        assertText(app, "6\"")  // take-up & mark1 = 6
        shot("smoke-stubup-en")
    }

    func test2OffsetEn() throws {
        let app = launch(mode: "offset", height: 20, angle: 22.5)
        assertText(app, "Offset height (in)")
        assertText(app, "2.613")      // multiplier 1/sin22.5
        app.swipeUp()
        assertText(app, "52-1/4\"")   // 20 × 2.613
        assertText(app, "3-3/4\"")    // shrink: 20 × 3/16(22.5° Benfield,角度函数)
        shot("smoke-offset-en")
    }

    func test3Saddle3En() throws {
        let app = launch(mode: "saddle3", height: 2)
        app.swipeUp()
        assertText(app, "5\"")        // side spacing = 2 × 2.5(Benfield 惯例)
        assertText(app, "2\"")        // center offset = width/2
        assertText(app, "22.5°")
        assertText(app, "45°")
        shot("smoke-saddle3-en")
    }

    func test4Saddle4En() throws {
        let app = launch(mode: "saddle4", height: 3)
        app.swipeUp()
        assertText(app, "7-1/2\"")    // spacing 6 + 1.5
        assertText(app, "6\"")        // rise spacing = obstacle width
        shot("smoke-saddle4-en")
    }

    func test5KickEn() throws {
        let app = launch(mode: "kick", height: 3, angle: 30)
        assertText(app, "5-3/16\"")   // 3 / tan30 = 5.196
        shot("smoke-kick-en")
    }

    // MARK: - 四语切换

    func test6OffsetZhHans() throws {
        let app = launch(mode: "offset", height: 20, angle: 22.5, language: "zh-Hans")
        assertText(app, "Z 弯高度(英寸)")
        app.swipeUp()
        assertText(app, "两标记间距")
        assertText(app, "52-1/4\"")
        shot("smoke-offset-zhHans")
    }

    func test7StubUpZhHant() throws {
        let app = launch(language: "zh-Hant")
        assertText(app, "扣除量")
        assertText(app, "第一標記")
        shot("smoke-stubup-zhHant")
    }

    func test8StubUpJa() throws {
        let app = launch(language: "ja")
        assertText(app, "テイクアップ")
        assertText(app, "マーク1")
        shot("smoke-stubup-ja")
    }
}
