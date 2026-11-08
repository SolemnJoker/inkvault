import SwiftUI
import UIKit

/// 打开模式（三态：阅读 / 编辑 / 分屏实时预览；raw 值用于持久化）。
enum NoteMode: String, Equatable {
    case reading
    case editing
    case split
}

/// 应用级状态与依赖装配。
@MainActor
final class AppModel: ObservableObject {
    let registry = VaultRegistry.shared
    let syncSettings = SyncConfigStore.shared
    let sync = SyncCoordinatorHolder.shared.coordinator
    let writer = VaultWriter.shared

    @Published var session: VaultSession?
    @Published var conflictService: ConflictService?
    @Published var selectedPath: String?
    @Published var mode: NoteMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "noteMode") }
    }
    /// 授权失效标记（US-01）
    @Published var vaultAuthorizationLost = false
    @Published var showAddVault = false
    @Published var showSyncScreen = false
    @Published var showSettings = false
    @Published var showConflictCompare: ConflictPair?
    @Published var toast: String?

    init() {
        mode = NoteMode(rawValue: UserDefaults.standard.string(forKey: "noteMode") ?? "") ?? .reading
        reopenCurrentVault()
    }

    // MARK: - vault 生命周期（US-01）

    var vaultURL: URL? { session?.rootURL }

    func reopenCurrentVault() {
        guard let record = registry.currentVault else { session = nil; return }
        openVault(record)
    }

    func openVault(_ record: VaultRecord) {
        let s = VaultSession(vault: record)
        AppModelHolderBridge.session = s
        guard s.open() != nil else {
            vaultAuthorizationLost = true
            session = s
            return
        }
        vaultAuthorizationLost = false
        session = s
        conflictService = ConflictService(session: s)
        conflictService?.rescan()
        selectedPath = nil
    }

    /// 重新授权后恢复（US-01：不丢未保存内容——编辑器内容在内存中，重授权后可继续保存）。
    func reauthorizeCurrentVault(at url: URL) {
        guard let session else { return }
        session.refreshBookmark(at: url)
        guard session.open() != nil else { return }
        vaultAuthorizationLost = false
        conflictService = ConflictService(session: session)
        conflictService?.rescan()
    }

    func switchVault(_ id: UUID) {
        registry.switchTo(id)
        reopenCurrentVault()
    }

    func removeVault(_ id: UUID) {
        registry.remove(id)
        reopenCurrentVault()
    }

    // MARK: - 场景阶段（功耗纪律 US-03 / D-05 / D-10）

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            EditorSaveHub.shared.flushAll()        // D-10：挂起前落盘
            DiagramRenderEngine.shared.tearDown()  // D-01：离屏渲染引擎随即销毁
            Task { await sync.stopNow() }          // D-05：立即停内核
        default:
            break
        }
    }

    // MARK: - 新建笔记 / 每日笔记

    /// 在库根新建笔记，返回相对路径（重名自动加序号）。
    func createNote(named rawName: String) -> String? {
        guard let root = session?.rootURL else { return nil }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "未命名" }
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        name = name.components(separatedBy: forbidden).joined(separator: "-")
        if name.isEmpty { name = "未命名" }
        let rel = name + ".md"
        let url = root.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? writer.write("", to: url)
            conflictService?.rescan()
            return rel
        }
        var i = 1
        while true {
            let relN = "\(name) \(i).md"
            let urlN = root.appendingPathComponent(relN)
            if !FileManager.default.fileExists(atPath: urlN.path) {
                try? writer.write("", to: urlN)
                conflictService?.rescan()
                return relN
            }
            i += 1
        }
    }

    /// 每日笔记：存在则直接打开，不存在则按模板创建（frontmatter.create 对齐用户工作流）。
    func openOrCreateDailyNote() -> String? {
        guard let root = session?.rootURL else { return nil }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let name = day.string(from: Date())
        let rel = name + ".md"
        let url = root.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: url.path) {
            let ts = DateFormatter()
            ts.dateFormat = "yyyy-MM-dd HH:mm"
            let content = "---\ncreate: \(ts.string(from: Date()))\n---\n\n# \(name)\n\n"
            try? writer.write(content, to: url)
            conflictService?.rescan()
        }
        return rel
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}

/// 编辑器保存中枢：所有编辑器实例注册防抖器，进后台统一 flush。
final class EditorSaveHub {
    static let shared = EditorSaveHub()
    private var debouncers: [ObjectIdentifier: Debouncer] = [:]
    private let lock = NSLock()

    func register(_ id: ObjectIdentifier, _ d: Debouncer) {
        lock.lock(); debouncers[id] = d; lock.unlock()
    }

    func unregister(_ id: ObjectIdentifier) {
        lock.lock(); debouncers.removeValue(forKey: id); lock.unlock()
    }

    func flushAll() {
        lock.lock(); let all = Array(debouncers.values); lock.unlock()
        all.forEach { $0.flush() }
    }
}
