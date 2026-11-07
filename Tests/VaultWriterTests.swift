import XCTest
@testable import InkVault

final class VaultWriterTests: XCTestCase {
    private var dir: URL!
    private var writer: VaultWriter!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer = VaultWriter()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAtomicWriteCreatesFile() throws {
        let url = dir.appendingPathComponent("note.md")
        try writer.write("hello", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
    }

    func testNoHalfWrittenTempFiles() throws {
        let url = dir.appendingPathComponent("note.md")
        for i in 0..<20 {
            try writer.write("content \(i)", to: url)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".inkvault-tmp") }
        XCTAssertTrue(leftovers.isEmpty, "残留临时文件: \(leftovers)")
    }

    func testCreationDatePreservedOnReplace() throws {
        let url = dir.appendingPathComponent("note.md")
        try writer.write("v1", to: url)
        let oldDate = Date(timeIntervalSinceNow: -86_400)
        try FileManager.default.setAttributes([.creationDate: oldDate], ofItemAtPath: url.path)
        try writer.write("v2", to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let creation = attrs[.creationDate] as? Date
        XCTAssertNotNil(creation)
        // 创建时间应保留（D-10）：与旧值相差小于 5 秒
        XCTAssertLessThan(abs(creation!.timeIntervalSince(oldDate)), 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "v2")
    }

    func testTrashToVaultMovesIntoTrashDir() throws {
        let url = dir.appendingPathComponent("gone.md")
        try writer.write("bye", to: url)
        try writer.trashToVault(url, vaultRoot: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let trash = dir.appendingPathComponent(".trash/gone.md")
        XCTAssertEqual(try String(contentsOf: trash, encoding: .utf8), "bye")
    }

    func testHiddenNameDetection() {
        XCTAssertTrue(VaultInternal.isHiddenName(".obsidian"))
        XCTAssertTrue(VaultInternal.isHiddenName(".trash"))
        XCTAssertTrue(VaultInternal.isHiddenName(".git"))
        XCTAssertTrue(VaultInternal.isHiddenName(".stfolder"))
        XCTAssertTrue(VaultInternal.isHiddenName(".stignore"))
        XCTAssertFalse(VaultInternal.isHiddenName("notes.md"))
        XCTAssertFalse(VaultInternal.isHiddenName("my.folder"))
    }
}

final class ConflictServiceTests: XCTestCase {
    private var root: URL!
    private var service: ConflictService!
    private var session: VaultSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session = VaultSession(forTesting: root)
        service = ConflictService(session: session)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeOriginal(_ name: String, content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testConflictDiscovery() throws {
        _ = try makeOriginal("note.md", content: "local")
        _ = try makeOriginal("note.sync-conflict-20261108-010203-ABC1234.md", content: "remote")
        service.rescan()
        let exp = expectation(description: "rescan")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(service.pairs.count, 1)
        XCTAssertEqual(service.pairs[0].originalPath, "note.md")
        XCTAssertEqual(service.pairs[0].conflictPaths.count, 1)
    }

    func testKeepLocalDeletesConflictCopy() throws {
        let original = try makeOriginal("note.md", content: "local")
        let conflict = try makeOriginal("note.sync-conflict-20261108-010203-ABC1234.md", content: "remote")
        try service.resolve(pair: ConflictPair(originalPath: "note.md", conflictPaths: [conflict.path]), resolution: .keepLocal)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.path))
    }

    func testKeepRemoteReplacesOriginal() throws {
        let original = try makeOriginal("note.md", content: "local")
        let conflict = try makeOriginal("note.sync-conflict-20261108-010203-ABC1234.md", content: "remote")
        try service.resolve(pair: ConflictPair(originalPath: "note.md", conflictPaths: [conflict.path]), resolution: .keepRemote)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "remote")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.path))
    }

    func testKeepBothRenamesConflict() throws {
        let original = try makeOriginal("note.md", content: "local")
        let conflict = try makeOriginal("note.sync-conflict-20261108-010203-ABC1234.md", content: "remote")
        try service.resolve(pair: ConflictPair(originalPath: "note.md", conflictPaths: [conflict.path]), resolution: .keepBoth)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("note-conflict-") && $0.hasSuffix(".md") })
    }

    func testOriginalPathRoundTrip() {
        let conflict = "/vault/note.sync-conflict-20261108-010203-ABC1234.md"
        XCTAssertEqual(ConflictService.originalPath(forConflict: conflict), "/vault/note.md")
        let noExt = "/vault/notes.sync-conflict-20261108-010203-ABC1234.md"
        XCTAssertEqual(ConflictService.originalPath(forConflict: noExt), "/vault/notes.md")
    }
}

final class SearchServiceTests: XCTestCase {
    func testFilenameAndContentSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "牛奶与蜂蜜的配方".write(to: root.appendingPathComponent("recipe.md"), atomically: true, encoding: .utf8)
        try "无关内容".write(to: root.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)

        let session = VaultSession(forTesting: root)
        let results = await SearchService(session: session).search("牛奶")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].path, "recipe.md")
        XCTAssertEqual(results[0].matchType, .content)

        let byName = await SearchService(session: session).search("recipe")
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName[0].matchType, .filename)

        // 隐藏目录必须被排除（US-09）
        let hidden = await SearchService(session: session).search("app.json")
        XCTAssertTrue(hidden.isEmpty)
    }
}
