import SwiftUI
import UIKit

/// 打开模式。
enum NoteMode: Equatable {
    case reading
    case editing
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
    @Published var mode: NoteMode = .reading
    /// 授权失效标记（US-01）
    @Published var vaultAuthorizationLost = false
    @Published var showAddVault = false
    @Published var showSyncScreen = false
    @Published var showSettings = false
    @Published var showConflictCompare: ConflictPair?
    @Published var toast: String?

    init() {
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
            EditorSaveHub.shared.flushAll()   // D-10：挂起前落盘
            Task { await sync.stopNow() }     // D-05：立即停内核
        default:
            break
        }
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
