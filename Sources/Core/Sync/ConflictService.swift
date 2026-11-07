import Foundation

struct ConflictPair: Identifiable, Equatable {
    var id: String { originalPath }
    /// 本地版本（原文件，不含冲突标记）
    var originalPath: String
    /// 远端冲突副本 `name.sync-conflict-YYYYMMDD-HHMMSS-DEVID.ext`
    var conflictPaths: [String]

    var displayName: String {
        (originalPath as NSString).lastPathComponent
    }
}

/// 冲突可见与处理（US-08 + 需求方确认策略）：
/// Syncthing 内核在两端同时修改时生成 `.sync-conflict-*` 副本；
/// App 负责发现、标记、对比、取舍，并在解决后清理败方。
final class ConflictService: ObservableObject {
    @Published private(set) var pairs: [ConflictPair] = []

    static let conflictMarker = ".sync-conflict-"

    private let session: VaultSession
    private let writer: VaultWriter

    init(session: VaultSession, writer: VaultWriter = .shared) {
        self.session = session
        self.writer = writer
    }

    /// 扫描全库冲突副本（跳过隐藏目录）。
    func rescan() {
        guard let root = session.rootURL else { pairs = []; return }
        var allConflicts: [String] = []
        walk(root) { url in
            if url.lastPathComponent.contains(Self.conflictMarker), !VaultInternal.isHiddenPath(url) {
                allConflicts.append(url.path)
            }
        }
        var byOriginal: [String: [String]] = [:]
        for path in allConflicts {
            byOriginal[Self.originalPath(forConflict: path), default: []].append(path)
        }
        var result: [ConflictPair] = []
        for (originalAbs, conflicts) in byOriginal {
            let rel = originalAbs.hasPrefix(root.path + "/")
                ? String(originalAbs.dropFirst(root.path.count + 1))
                : originalAbs
            result.append(ConflictPair(originalPath: rel, conflictPaths: conflicts.sorted()))
        }
        DispatchQueue.main.async { [weak self] in
            self?.pairs = result.sorted { $0.originalPath < $1.originalPath }
        }
    }

    /// 读取原始文件与冲突副本内容供对比。
    func loadContents(pair: ConflictPair) -> (local: String, remote: [(path: String, text: String)]) {
        let local = (try? String(contentsOf: session.absoluteURL(for: pair.originalPath), encoding: .utf8)) ?? ""
        var remote: [(String, String)] = []
        for cp in pair.conflictPaths {
            let text = (try? String(contentsOfFile: cp, encoding: .utf8)) ?? ""
            remote.append((cp, text))
        }
        return (local, remote)
    }

    enum Resolution {
        case keepLocal
        case keepRemote
        case keepBoth
    }

    /// 解决一个冲突对。MUST NOT 覆盖未明确选择的版本（US-08）。
    func resolve(pair: ConflictPair, resolution: Resolution) throws {
        let originalURL = session.absoluteURL(for: pair.originalPath)
        let conflictURLs = pair.conflictPaths.map { URL(fileURLWithPath: $0) }
        switch resolution {
        case .keepLocal:
            // 本地胜：删除全部冲突副本
            for c in conflictURLs { try writer.removeCompletely(c) }
        case .keepRemote:
            // 远端胜：冲突副本（取最新一份）原子替换本地，其余删除
            guard let first = conflictURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last,
                  let data = try? Data(contentsOf: first)
            else { return }
            if let originalURL { try writer.write(data, to: originalURL) }
            for c in conflictURLs { try writer.removeCompletely(c) }
        case .keepBoth:
            // 都保留：冲突副本改名为「原名-conflict-时间戳」留在 vault
            let stamp = DateFormatter.fallbackStamp.string(from: Date())
            for (i, c) in conflictURLs.enumerated() {
                let base = c.deletingPathExtension()
                let ext = c.pathExtension
                let newName = base.lastPathComponent + "-conflict-\(stamp)\(i > 0 ? "-\(i)" : "")" + (ext.isEmpty ? "" : "." + ext)
                let target = c.deletingLastPathComponent().appendingPathComponent(newName)
                try FileManager.default.moveItem(at: c, to: target)
            }
        }
        rescan()
    }

    /// 从冲突文件名还原原文件路径。
    static func originalPath(forConflict absPath: String) -> String {
        let ns = absPath as NSString
        let name = ns.lastPathComponent
        guard let markerRange = name.range(of: conflictMarker) else { return absPath }
        // 从标记处向后找到 "-" 分隔的设备 ID 结束（DEVID 7 位大写字母数字）
        let afterMarker = name[markerRange.upperBound...] // YYYYMMDD-HHMMSS-DEVID
        // 冲突名结构：<base>.<ext>.sync-conflict-<stamp>-<devid>.<ext>
        // 原文件名 = 标记前的部分 + 冲突副本的最后扩展名
        let baseWithExt = String(name[..<markerRange.lowerBound])
        let finalExt = (ns.pathExtension != "" && !name.hasSuffix(ns.pathExtension)) ? "." + ns.pathExtension : ""
        _ = afterMarker
        return ns.deletingLastPathComponent.appendingPathComponent(baseWithExt + finalExt).path
    }

    private func walk(_ root: URL, _ visit: (URL) -> Void) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for item in items {
            if VaultInternal.isHiddenName(item.lastPathComponent) { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                walk(item, visit)
            } else {
                visit(item)
            }
        }
    }
}

extension DateFormatter {
    static let fallbackStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
