import Foundation

/// vault 内部目录与隐藏规则（US-09、D-04）。
enum VaultInternal {
    static let hiddenDirectories = [".obsidian", ".trash", ".git", ".stfolder", ".stversions", ".inkvault"]
    static let hiddenFiles = [".stignore", ".inkvault-meta.json"]

    static func isHiddenName(_ name: String) -> Bool {
        if hiddenDirectories.contains(name) || hiddenFiles.contains(name) { return true }
        if name.hasPrefix(".") && name.hasSuffix(".tmp") { return true }
        return false
    }

    static func isHiddenPath(_ url: URL) -> Bool {
        url.pathComponents.contains(where: isHiddenName)
    }
}

struct VaultOperation: Codable {
    var timestamp: Date
    var relativePath: String
    var operation: String // create | write | delete | rename
    var sizeBefore: Int?
    var sizeAfter: Int?
}

/// 所有对 vault 的写入统一经此（D-09）。
/// 语义：临时文件 + 原子替换（D-10），保留创建时间与 POSIX 权限；
/// 沙盒内 append-only 操作日志供未来版本历史（US-13）与溯源使用。
final class VaultWriter {
    static let shared = VaultWriter()

    private let logQueue = DispatchQueue(label: "inkvault.vaultwriter.log")
    private var logHandle: FileHandle?
    private var logURL: URL { AppPaths.operationLog }

    init() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.seekToEnd()
    }

    deinit { try? logHandle?.close() }

    // MARK: - 写

    /// 原子写入文本。返回是否成功。
    @discardableResult
    func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }

    @discardableResult
    func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let creation = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber

        let tmp = dir.appendingPathComponent(".inkvault-tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }

        // 原子替换后回写创建时间与权限（D-10）
        var attrs: [FileAttributeKey: Any] = [:]
        if let creation { attrs[.creationDate] = creation }
        if let permissions { attrs[.posixPermissions] = permissions }
        if !attrs.isEmpty {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
        logOperation(VaultOperation(timestamp: Date(), relativePath: url.path, operation: "write", sizeBefore: sizeBefore, sizeAfter: data.count))
    }

    func delete(_ url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        logOperation(VaultOperation(timestamp: Date(), relativePath: url.path, operation: "delete", sizeBefore: size, sizeAfter: nil))
    }

    /// Obsidian 语义：删除即移入 vault 根的 .trash/（D-04）。
    func trashToVault(_ url: URL, vaultRoot: URL) throws {
        let trashDir = vaultRoot.appendingPathComponent(".trash", isDirectory: true)
        if !FileManager.default.fileExists(atPath: trashDir.path) {
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        }
        var target = trashDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            target = trashDir.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        try FileManager.default.moveItem(at: url, to: target)
        logOperation(VaultOperation(timestamp: Date(), relativePath: url.path, operation: "delete", sizeBefore: size, sizeAfter: nil))
    }

    /// 冲突解决后的败方清理（需求方确认策略）：直接删除，vault 恢复无痕。
    func removeCompletely(_ url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        try FileManager.default.removeItem(at: url)
        logOperation(VaultOperation(timestamp: Date(), relativePath: url.path, operation: "delete", sizeBefore: size, sizeAfter: nil))
    }

    // MARK: - 日志

    private func logOperation(_ op: VaultOperation) {
        logQueue.async { [weak self] in
            guard let self, let handle = self.logHandle else { return }
            guard let line = try? JSONEncoder().encode(op) else { return }
            handle.write(Data(line + Array("\n".utf8)))
        }
    }
}
