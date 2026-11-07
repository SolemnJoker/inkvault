import Foundation

struct VaultRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// security-scoped bookmark（US-01：重启后免重选）
    var bookmarkData: Data
    var createdAt: Date
}

/// 多 vault 注册表；数据存沙盒。
final class VaultRegistry: ObservableObject {
    @Published private(set) var vaults: [VaultRecord] = []
    @Published var currentVaultID: UUID?

    static let shared = VaultRegistry()

    private let fileURL = AppPaths.vaultRegistry

    init() {
        load()
        if let saved = UserDefaults.standard.string(forKey: "currentVaultID") {
            currentVaultID = UUID(uuidString: saved)
        }
        if currentVaultID == nil { currentVaultID = vaults.first?.id }
    }

    var currentVault: VaultRecord? {
        vaults.first { $0.id == currentVaultID }
    }

    func add(name: String, bookmarkData: Data) -> VaultRecord {
        let record = VaultRecord(id: UUID(), name: name, bookmarkData: bookmarkData, createdAt: Date())
        vaults.append(record)
        currentVaultID = record.id
        save()
        return record
    }

    func remove(_ id: UUID) {
        vaults.removeAll { $0.id == id }
        if currentVaultID == id { currentVaultID = vaults.first?.id }
        save()
    }

    func switchTo(_ id: UUID) {
        currentVaultID = id
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(vaults) {
            try? data.write(to: fileURL, options: .atomic)
        }
        UserDefaults.standard.set(currentVaultID?.uuidString, forKey: "currentVaultID")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([VaultRecord].self, from: data)
        else { return }
        vaults = list
    }
}

/// 一个已打开 vault 的会话：解析 bookmark、维护访问权限与根 URL。
final class VaultSession {
    private(set) var vault: VaultRecord
    private(set) var rootURL: URL?
    private var accessing = false

    init(vault: VaultRecord) { self.vault = vault }

    /// 测试/预览专用：直接指定根目录。
    init(forTesting root: URL) {
        vault = VaultRecord(id: UUID(), name: "test", bookmarkData: Data(), createdAt: Date())
        rootURL = root
        accessing = false
    }
    deinit { endAccess() }

    /// 解析 bookmark 并开始访问。返回 nil = 授权失效（US-01：需重新授权引导）。
    func open() -> URL? {
        endAccess()
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: vault.bookmarkData,
                                 options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else {
            rootURL = nil
            return nil
        }
        accessing = true
        if stale { refreshBookmark(at: url) }
        rootURL = url
        return url
    }

    /// 用户重新授权后刷新 bookmark。
    func refreshBookmark(at url: URL) {
        guard let data = try? url.bookmarkData() else { return }
        vault.bookmarkData = data
        VaultRegistry.shared.updateBookmark(vaultID: vault.id, bookmarkData: data)
    }

    func endAccess() {
        if accessing, let root = rootURL {
            root.stopAccessingSecurityScopedResource()
            accessing = false
        }
    }

    // MARK: - 文件树（懒加载，US-11）

    struct Entry: Identifiable, Equatable {
        var id: String { path }
        var path: String        // 相对 vault 根
        var name: String
        var isDirectory: Bool
        var hasConflict: Bool = false
    }

    /// 列出某相对目录的可见子项（隐藏内部目录，US-09）。
    func listDirectory(relative: String) -> [Entry] {
        guard let root = rootURL else { return [] }
        let dir = relative.isEmpty ? root : root.appendingPathComponent(relative)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: []) else { return [] }
        return items
            .filter { !VaultInternal.isHiddenName($0.lastPathComponent) }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return Entry(path: relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent,
                             name: url.lastPathComponent,
                             isDirectory: isDir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    func absoluteURL(for relativePath: String) -> URL? {
        guard let root = rootURL else { return nil }
        return root.appendingPathComponent(relativePath)
    }
}

extension VaultRegistry {
    func updateBookmark(vaultID: UUID, bookmarkData: Data) {
        guard let idx = vaults.firstIndex(where: { $0.id == vaultID }) else { return }
        vaults[idx].bookmarkData = bookmarkData
        save()
    }
}
