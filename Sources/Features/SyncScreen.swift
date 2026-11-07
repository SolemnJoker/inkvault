import SwiftUI
import Network

/// 同步主界面：状态/按钮/报告 + 首次配置向导 + 同意流程。
struct SyncScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SyncConfigStore.shared
    @ObservedObject private var coordinator = SyncCoordinatorHolder.shared.coordinator

    @State private var showWizard = false
    @State private var cellularConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                configSection
                reportSection
            }
            .navigationTitle("同步")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .sheet(isPresented: $showWizard) { SyncWizard() }
            .alert("使用蜂窝网络同步？", isPresented: $cellularConfirm) {
                Button("开始同步") { startSync(force: true) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前为蜂窝网络。继续将经中继传输数据，可能消耗流量。")
            }
        }
    }

    private var statusSection: some View {
        Section("状态") {
            if coordinator.state == .idle {
                Button {
                    startSync(force: false)
                } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.isConfigured || !settings.consentGiven)
            } else {
                HStack {
                    ProgressView()
                    Text(progressText)
                    Spacer()
                    Button("停止", role: .destructive) {
                        Task { await coordinator.stopNow() }
                    }
                }
            }
            if !settings.isConfigured || !settings.consentGiven {
                Button {
                    showWizard = true
                } label: {
                    Label("完成首次配置", systemImage: "wand.and.stars")
                }
            }
        }
    }

    private var progressText: String {
        switch coordinator.state {
        case .starting: return "启动内核中…"
        case .syncing: return coordinator.progressNote.isEmpty ? "同步中…" : coordinator.progressNote
        case .stopping: return "停止中…"
        case .idle: return ""
        }
    }

    private var configSection: some View {
        Section("配置") {
            LabeledContent("远端设备") {
                Text(settings.settings.remoteName.isEmpty ? settings.settings.remoteDeviceID : settings.settings.remoteName)
                    .font(.footnote)
            }
            LabeledContent("本机设备 ID") {
                Text(kernelDeviceID).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            Button("修改配置") { showWizard = true }
            Button("关于同步的说明") { showWizard = true } // 说明包含在向导中（D-11）
        }
    }

    @ViewBuilder
    private var reportSection: some View {
        if let report = coordinator.lastReport {
            Section("上次同步") {
                LabeledContent("结果", value: report.success ? "成功" : "失败")
                if let failure = report.failure {
                    Text(failure.localizedDescription).foregroundStyle(.red)
                }
                LabeledContent("耗时", value: String(format: "%.1f 秒", report.finishedAt.timeIntervalSince(report.startedAt)))
                if let errs = report.pullErrors, errs > 0 {
                    LabeledContent("冲突/错误条目", value: "\(errs)")
                }
            }
        }
        if let conflicts = model.conflictService, !conflicts.pairs.isEmpty {
            Section("待处理冲突（\(conflicts.pairs.count)）") {
                ForEach(conflicts.pairs) { pair in
                    Button {
                        model.showConflictCompare = pair
                    } label: {
                        Label(pair.displayName, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var kernelDeviceID: String {
        KernelInfo.cachedDeviceID
    }

    private func startSync(force: Bool) {
        guard let url = model.vaultURL else {
            model.showToast("未打开笔记库")
            return
        }
        if !force, isCellular() {
            cellularConfirm = true
            return
        }
        Task { await coordinator.runManualSync(vaultURL: url) }
    }

    private func isCellular() -> Bool {
        let monitor = NWPathMonitor()
        let sema = DispatchSemaphore(value: 0)
        var expensive = false
        monitor.pathUpdateHandler = { path in
            expensive = path.isExpensive == false && path.usesInterfaceType(.cellular)
            sema.signal()
        }
        monitor.start(queue: DispatchQueue.global())
        _ = sema.wait(timeout: .now() + 1.5)
        monitor.cancel()
        return expensive
    }
}

@MainActor
final class SyncCoordinatorHolder {
    static let shared = SyncCoordinatorHolder()
    let coordinator = SyncCoordinator()
}

/// 一次性读取内核设备 ID（启动内核会耗资源，这里只在配置向导需要时启动）。
@MainActor
enum KernelInfo {
    static var cachedDeviceID: String {
        if KernelBridge.isRunning { return KernelBridge.myDeviceID }
        return UserDefaults.standard.string(forKey: "kernelDeviceID") ?? "（打开同步后可见）"
    }

    static func probeAndCache() {
        if KernelBridge.isRunning {
            UserDefaults.standard.set(KernelBridge.myDeviceID, forKey: "kernelDeviceID")
        }
    }
}

// MARK: - 首次配置向导（US-07 配置 / D-08 同意 / D-11 披露）

struct SyncWizard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SyncConfigStore.shared

    @State private var relayURI = ""
    @State private var remoteID = ""
    @State private var remoteName = ""
    @State private var conflictConsent = false
    @State private var stfolderConsent = false
    @State private var step = 0

    var body: some View {
        NavigationStack {
            Form {
                if step == 0 { connectionStep }
                if step == 1 { consentStep }
                if step == 2 { disclosureStep }
            }
            .navigationTitle("同步配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if step < 2 {
                        Button("下一步") { step += 1 }
                            .disabled(step == 0 ? (relayURI.isEmpty || remoteID.count < 20) : !(conflictConsent && stfolderConsent))
                    } else {
                        Button("完成") { finish() }
                    }
                }
            }
        }
    }

    private var connectionStep: some View {
        Section {
            TextField("中继地址（relay://…）", text: $relayURI)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("远端设备 ID（XXXXXX-XXXXXX-…）", text: $remoteID)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("远端名称（可选）", text: $remoteName)
        } header: {
            Text("连接")
        } footer: {
            Text("仅使用你自建的私有中继，不连接任何公共中继池或发现服务；局域网内可用本地发现直连。")
        }
    }

    private var consentStep: some View {
        Section {
            Toggle(isOn: $conflictConsent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("允许生成冲突副本文件")
                    Text("两端同时修改同一文件时，同步会在库内生成 .sync-conflict-* 副本（默认隐藏显示）。App 会标记并引导你对比取舍，解决后自动清理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $stfolderConsent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("允许写入 .stfolder 标记目录")
                    Text("同步内核需要在库根创建 .stfolder 标记目录以标识同步范围（默认隐藏）。这是 App 唯一写入 vault 的同步产物。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("写入授权（D-08）")
        } footer: {
            Text("拒绝将无法开启同步。除上述两项外，App 不向库内写入任何同步文件；凭证与配置只存本机沙盒。")
        }
    }

    private var disclosureStep: some View {
        Section {
            Text("中继只转发加密数据，无法读取你的笔记内容；但中继会知晓你设备的 IP 地址与设备 ID，并能观测流量规模。数据不会经过任何第三方云服务。")
                .font(.callout)
            Text("凭证（API Key、设备证书）保存在本机安全存储（Keychain/沙盒），绝不写入笔记库。")
                .font(.callout)
        } header: {
            Text("关于元数据（如实披露）")
        } footer: {
            Text("点击「完成」保存配置。之后可随时在设置中修改。")
        }
    }

    private func finish() {
        settings.settings.relayURI = relayURI.trimmingCharacters(in: .whitespaces)
        settings.settings.remoteDeviceID = remoteID.trimmingCharacters(in: .whitespaces).uppercased()
        settings.settings.remoteName = remoteName
        settings.settings.conflictConsentGiven = conflictConsent
        settings.settings.stfolderConsentGiven = stfolderConsent
        dismiss()
    }
}
