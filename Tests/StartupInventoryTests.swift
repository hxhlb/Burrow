//
//  StartupInventoryTests.swift
//  BurrowTests
//
//  The Startup segment (design 2.4) enumerates launch agents/daemons
//  from the world-readable plist directories — no admin needed for the
//  large majority. Classification and error detection are pure file
//  reads, tested against scratch directories; the view only renders
//  what this layer reports. Broken rows (unparseable plist, dangling
//  executable) surface as errors instead of being hidden.
//

import XCTest
@testable import Burrow

final class StartupInventoryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writePlist(_ name: String, _ contents: [String: Any]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    func testItem_readsLabelAndProgram() throws {
        let url = try writePlist("com.example.agent.plist",
                                 ["Label": "com.example.agent", "Program": "/bin/echo"])
        let item = StartupInventory.item(fromPlist: url, kind: .launchAgent, scope: .user)
        XCTAssertEqual(item.label, "com.example.agent")
        XCTAssertEqual(item.executable, "/bin/echo")
        XCTAssertNil(item.problem)
    }

    func testItem_programArgumentsFirstElementIsTheExecutable() throws {
        let url = try writePlist("com.example.args.plist",
                                 ["Label": "com.example.args",
                                  "ProgramArguments": ["/usr/bin/true", "--flag"]])
        let item = StartupInventory.item(fromPlist: url, kind: .launchDaemon, scope: .system)
        XCTAssertEqual(item.executable, "/usr/bin/true")
    }

    func testItem_danglingExecutableIsAnError() throws {
        let url = try writePlist("com.example.gone.plist",
                                 ["Label": "com.example.gone",
                                  "Program": "/nonexistent/binary/xyz"])
        let item = StartupInventory.item(fromPlist: url, kind: .launchAgent, scope: .user)
        XCTAssertEqual(item.problem, .danglingExecutable)
    }

    func testItem_corruptPlistIsAnError() throws {
        let url = dir.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: url)
        let item = StartupInventory.item(fromPlist: url, kind: .launchAgent, scope: .user)
        XCTAssertEqual(item.problem, .parseFailed)
        XCTAssertEqual(item.label, "broken", "falls back to the filename")
    }

    /// Helpers that live inside an app bundle are managed by that app —
    /// review-only in the UI ("Bundled inside an app; review only").
    func testBundledInApp_detection() throws {
        let bundled = try writePlist("com.example.helper.plist",
                                     ["Label": "com.example.helper",
                                      "Program": "/Applications/Foo.app/Contents/MacOS/helper"])
        XCTAssertTrue(StartupInventory.item(fromPlist: bundled, kind: .launchAgent, scope: .user).bundledInApp)
        let loose = try writePlist("com.example.loose.plist",
                                   ["Label": "com.example.loose", "Program": "/bin/echo"])
        XCTAssertFalse(StartupInventory.item(fromPlist: loose, kind: .launchAgent, scope: .user).bundledInApp)
    }

    func testScan_directoryEnumeration() throws {
        _ = try writePlist("com.a.plist", ["Label": "com.a", "Program": "/bin/echo"])
        _ = try writePlist("com.b.plist", ["Label": "com.b", "Program": "/bin/echo"])
        try Data().write(to: dir.appendingPathComponent("not-a-plist.txt"))
        let items = StartupInventory.scan(directory: dir, kind: .launchAgent, scope: .user)
        XCTAssertEqual(items.map(\.label).sorted(), ["com.a", "com.b"])
    }

    func testScan_missingDirectoryIsEmpty() {
        let items = StartupInventory.scan(directory: dir.appendingPathComponent("nope"),
                                          kind: .launchDaemon, scope: .system)
        XCTAssertTrue(items.isEmpty)
    }
}
