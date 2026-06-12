//
//  UpdateSourcesTests.swift
//  BurrowTests
//
//  Update-source detection (design 2.3): which mechanism updates an
//  app — Mac App Store receipt, Sparkle feed, Electron's updater, or
//  Homebrew. Detection reads bundle *shape* (testable with scratch
//  bundles); the network checkers parse fixed formats (appcast XML,
//  iTunes lookup JSON) pinned here.
//

import XCTest
@testable import Burrow

final class UpdateSourcesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-updatesources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeApp(name: String, infoPlist: [String: Any],
                         masReceipt: Bool = false, electron: Bool = false) throws -> String {
        let app = dir.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if masReceipt {
            let receiptDir = contents.appendingPathComponent("_MASReceipt")
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: receiptDir.appendingPathComponent("receipt"))
        }
        if electron {
            let fw = contents.appendingPathComponent("Frameworks/Electron Framework.framework")
            try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        }
        return app.path
    }

    func testDetect_sparkleFromSUFeedURL() throws {
        let app = try makeApp(name: "Sparkly",
                              infoPlist: ["CFBundleShortVersionString": "1.0",
                                          "SUFeedURL": "https://example.com/appcast.xml"])
        XCTAssertEqual(UpdateSources.detect(appPath: app), .sparkle)
    }

    func testDetect_masReceiptWinsOverSparkle() throws {
        let app = try makeApp(name: "Storey",
                              infoPlist: ["SUFeedURL": "https://example.com/appcast.xml"],
                              masReceipt: true)
        XCTAssertEqual(UpdateSources.detect(appPath: app), .appStore)
    }

    func testDetect_electronFramework() throws {
        let app = try makeApp(name: "Electra", infoPlist: [:], electron: true)
        XCTAssertEqual(UpdateSources.detect(appPath: app), .electron)
    }

    func testDetect_plainBundleIsUnknown() throws {
        let app = try makeApp(name: "Plain", infoPlist: ["CFBundleShortVersionString": "1.0"])
        XCTAssertNil(UpdateSources.detect(appPath: app))
    }

    // MARK: - Appcast

    func testParseAppcast_picksHighestVersion() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item><title>1.9</title>
              <enclosure url="https://x/old.zip" sparkle:version="190" sparkle:shortVersionString="1.9"/>
            </item>
            <item><title>2.1</title>
              <enclosure url="https://x/new.zip" sparkle:version="210" sparkle:shortVersionString="2.1"/>
            </item>
          </channel>
        </rss>
        """
        XCTAssertEqual(UpdateSources.parseAppcast(Data(xml.utf8)), "2.1")
    }

    func testParseAppcast_fallsBackToSparkleVersion() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><enclosure url="https://x/a.zip" sparkle:version="3.2.0"/></item>
        </channel></rss>
        """
        XCTAssertEqual(UpdateSources.parseAppcast(Data(xml.utf8)), "3.2.0")
    }

    func testParseAppcast_garbageIsNil() {
        XCTAssertNil(UpdateSources.parseAppcast(Data("not xml at all".utf8)))
    }

    // MARK: - iTunes lookup (MAS)

    func testParseITunesLookup_readsVersionAndPage() throws {
        let json = """
        {"resultCount":1,"results":[{"version":"3.4.1",
          "trackViewUrl":"https://apps.apple.com/app/id123"}]}
        """
        let result = try XCTUnwrap(UpdateSources.parseITunesLookup(Data(json.utf8)))
        XCTAssertEqual(result.version, "3.4.1")
        XCTAssertEqual(result.pageURL?.absoluteString, "https://apps.apple.com/app/id123")
    }

    func testParseITunesLookup_emptyResultsIsNil() {
        XCTAssertNil(UpdateSources.parseITunesLookup(Data("{\"resultCount\":0,\"results\":[]}".utf8)))
    }
}
