import SwiftUI

/// 设置（D-10 防抖可配 / US-06 输入法说明 / D-11 披露入口）。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveDebounceMs") private var saveDebounceMs = 1000
    @AppStorage("vimEnabled") private var vimEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("编辑") {
                    Toggle("Vim 模式", isOn: $vimEnabled)
                    VStack(alignment: .leading) {
                        LabeledContent("保存防抖", value: "\(saveDebounceMs) ms")
                        Slider(value: Binding(
                            get: { Double(saveDebounceMs) },
                            set: { saveDebounceMs = Int($0 / 100) * 100 }
                        ), in: 800...2000, step: 100)
                        Text("停止输入后延迟落盘的时间（800–2000ms，D-10）。更短=更实时，更长=更省电。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("中文输入说明（US-06）") {
                    Text("进入 Vim 的 INSERT 模式时，App 会尝试提示并切换输入法；受 iPadOS 系统限制，自动切换不总是可用——此时请手动切换到拼音输入法。NORMAL 模式下 App 会尽量强制英文输入法，避免方向键/命令触发拼音候选。")
                        .font(.callout)
                }

                Section("关于同步") {
                    NavigationLink("同步说明与元数据披露") {
                        SyncDisclosureView()
                    }
                    LabeledContent("内核版本", value: KernelInfo.cachedVersion)
                }

                Section("笔记库") {
                    ForEach(model.registry.vaults) { vault in
                        LabeledContent(vault.name, value: vault.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("添加新笔记库", role: nil) { model.showAddVault = true }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

struct SyncDisclosureView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("同步如何工作").font(.headline)
                Text("InkVault 内嵌 Syncthing 内核，仅在你在 App 内点击「同步」时启动，同步完成或退出到后台后立即停止；不存在后台同步、定时器或文件扫描。")
                Text("数据路径").font(.headline)
                Text("你的笔记只在本机与你配置的远端设备之间传输；跨网络时经你自建的私有中继服务器转发。不使用任何公共中继池、公共发现服务或第三方云。")
                Text("中继能看见什么（如实披露）").font(.headline)
                Text("中继只转发加密数据，无法读取笔记内容；但它会知晓你设备的 IP 地址与设备 ID，并能观测流量的规模与时间。InkVault 不宣称「无任何元数据暴露」或「完全匿名」。")
                Text("凭证存放").font(.headline)
                Text("同步配置、设备证书与 API Key 只保存在本机 App 沙盒与 Keychain 中，绝不写入笔记库，也不上传到任何第三方服务。")
                Text("冲突处理").font(.headline)
                Text("两端同时修改同一文件时，会在库内生成 .sync-conflict-* 副本（首次开启同步时已征得你的同意，默认隐藏显示）。App 会标记冲突并引导你对比、选择保留哪一版，解决后自动清理败方文件。")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("关于同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension KernelInfo {
    static var cachedVersion: String {
        if KernelBridge.isRunning { return KernelBridge.version }
        return UserDefaults.standard.string(forKey: "kernelVersion") ?? "未加载（同步时按需启动）"
    }
}
