import Foundation

/// 单次手动同步的结果报告（US-07）。
struct SyncReport: Equatable {
    var startedAt: Date
    var finishedAt: Date
    var success: Bool
    /// 分类原因（成功时为 nil）
    var failure: SyncError?
    var remoteBytesNeeded: Int?
    var remoteFilesNeeded: Int?
    var pullErrors: Int?
    var kernelVersion: String
}

/// 手动同步生命周期编排（D-05）：用户触发 → 启动内核 → 双向同步 → 停止内核。
/// 进入后台必须 stopNow（App 层在 scenePhase 变化时调用）。
@MainActor
final class SyncCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case syncing
        case stopping
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var progressNote = ""

    private let config: SyncConfigStore
    private let kernelHome: URL
    private var rest: SyncthingREST?

    init(config: SyncConfigStore = .shared, kernelHome: URL = AppPaths.syncHome) {
        self.config = config
        self.kernelHome = kernelHome
    }

    var isBusy: Bool { state != .idle }

    // MARK: - 主流程

    /// 执行一次手动同步。调用方需先处理蜂窝确认（US-07）。
    func runManualSync(vaultURL: URL) async {
        guard state == .idle else { return }
        guard config.isConfigured else { finish(started: Date(), success: false, failure: .notConfigured) ; return }
        guard config.consentGiven else { finish(started: Date(), success: false, failure: .notConsented); return }

        state = .starting
        progressNote = "正在启动同步内核…"
        let started = Date()
        let apiKey = config.apiKey
        let port = config.settings.apiPort

        do {
            if !KernelBridge.isRunning {
                try KernelBridge.start(homeDir: kernelHome, guiPort: port, apiKey: apiKey)
            }
            let client = SyncthingREST(port: Int(port), apiKey: apiKey)
            rest = client
            _ = try await client.systemStatus() // 就绪探测

            progressNote = "正在配置同步拓扑…"
            try await configureTopology(client: client, vaultURL: vaultURL)

            state = .syncing
            let report = try await waitUntilSettled(client: client, started: started)
            lastReport = report
            progressNote = ""
            state = .stopping
            try? KernelBridge.stop()
            rest = nil
            state = .idle
        } catch let e as SyncError {
            await shutdownAfterFailure()
            finish(started: started, success: false, failure: e)
        } catch {
            await shutdownAfterFailure()
            finish(started: started, success: false, failure: .network(error.localizedDescription))
        }
    }

    /// 进后台 / 用户手动停止（US-07：不驻留后台）。
    func stopNow() async {
        guard state != .idle else { return }
        progressNote = "正在停止…"
        await shutdownAfterFailure()
        progressNote = ""
    }

    private func shutdownAfterFailure() async {
        state = .stopping
        try? KernelBridge.stop()
        rest = nil
        state = .idle
    }

    private func finish(started: Date, success: Bool, failure: SyncError?) {
        lastReport = SyncReport(
            startedAt: started, finishedAt: Date(), success: success,
            failure: failure, remoteBytesNeeded: nil, remoteFilesNeeded: nil,
            pullErrors: nil, kernelVersion: KernelBridge.version
        )
    }

    // MARK: - 拓扑配置（幂等）

    /// 配置远端设备（地址 = 私有中继 + dynamic LAN）与共享 vault 文件夹（D-06）。
    private func configureTopology(client: SyncthingREST, vaultURL: URL) async throws {
        var cfg = try await client.config()
        let remoteID = config.settings.remoteDeviceID
        let relay = config.settings.relayURI
        let folderID = SyncConfigStore.folderID

        // 设备
        if !cfg.devices.contains(where: { $0.deviceID == remoteID }) {
            var dev = FullConfig.DeviceConfig(deviceID: remoteID)
            dev.name = config.settings.remoteName
            dev.addresses = relay.isEmpty ? ["dynamic"] : [relay, "dynamic"]
            cfg.devices.append(dev)
        } else if let idx = cfg.devices.firstIndex(where: { $0.deviceID == remoteID }) {
            // 保持中继地址最新（用户可能修改）
            cfg.devices[idx].addresses = relay.isEmpty ? ["dynamic"] : [relay, "dynamic"]
        }

        // 文件夹：syncthing 期望绝对路径
        if let idx = cfg.folders.firstIndex(where: { $0.id == folderID }) {
            cfg.folders[idx].path = vaultURL.path
            var devices = cfg.folders[idx].devices ?? []
            if !devices.contains(where: { $0.deviceID == remoteID }) {
                devices.append(FullConfig.FolderConfig.SharedDevice(deviceID: remoteID))
            }
            cfg.folders[idx].devices = devices
        } else {
            var folder = FullConfig.FolderConfig(id: folderID, path: vaultURL.path)
            folder.label = "InkVault"
            folder.filesystemType = "basic"
            folder.type = "sendreceive"
            folder.devices = [FullConfig.FolderConfig.SharedDevice(deviceID: remoteID)]
            folder.rescanIntervalS = 0      // 无常驻扫描（NFR-03）
            folder.fsWatcherEnabled = false // 无常驻文件监听（D-05）
            folder.ignorePerms = false
            folder.autoNormalize = true
            folder.minDiskFree = FullConfig.FolderConfig.UnitValue(value: 1, unit: "%")
            folder.versioning = nil         // D-12：明确不开启内核版本控制
            folder.paused = false
            cfg.folders.append(folder)
        }
        try await client.saveConfig(cfg)
    }

    // MARK: - 完成判定

    /// 等待双向同步稳定：连接建立 → folder 状态 idle 且 inSync==global 连续 2 次。
    private func waitUntilSettled(client: SyncthingREST, started: Date) async throws -> SyncReport {
        let remoteID = config.settings.remoteDeviceID
        let folder = SyncConfigStore.folderID
        let timeoutBudget: TimeInterval = 600 // T-02 待定项的临时上限，Spike 回填后调整
        var stableCount = 0

        // 等待与远端建立连接（含中继拨号时间）
        var connected = false
        while Date().timeIntervalSince(started) < 90 {
            let conns = try await client.connections()
            if conns.connections?[remoteID]?.connected == true { connected = true; break }
            try await Task.sleep(for: .seconds(2))
        }
        if !connected { throw SyncError.remoteNotConnected }

        while Date().timeIntervalSince(started) < timeoutBudget {
            let status = try await client.dbStatus(folder: folder)
            let global = status.globalBytes ?? 0
            let inSync = status.inSyncBytes ?? 0
            if status.state == "idle", inSync >= global {
                stableCount += 1
                if stableCount >= 2 {
                    return SyncReport(
                        startedAt: started, finishedAt: Date(), success: true, failure: nil,
                        remoteBytesNeeded: nil, remoteFilesNeeded: nil,
                        pullErrors: status.pullErrors, kernelVersion: KernelBridge.version
                    )
                }
            } else {
                stableCount = 0
                let pendingMB = Double(max(0, global - inSync)) / 1_048_576
                progressNote = String(format: "同步中：剩余 %.1f MB", pendingMB)
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw SyncError.syncTimeout
    }
}
