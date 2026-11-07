import SwiftUI

/// 编辑器整屏：文本视图 + vim 模式条（US-05：模式指示清晰可见）+ 保护弹窗。
struct EditorScreen: View {
    @EnvironmentObject private var model: AppModel
    let path: String
    let initialContent: String
    @StateObject private var coordinator = EditorCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            NoteEditorView(coordinator: coordinator)
            VimModeBar(coordinator: coordinator)
        }
        .onAppear {
            AppModelHolderBridge.session = model.session
            coordinator.load(path: path, content: initialContent)
        }
        .onChange(of: path) { _, newPath in
            coordinator.load(path: newPath, content: initialContent)
        }
        .onDisappear {
            coordinator.flushPendingSave()
        }
        .alert("文件已被外部修改", isPresented: Binding(
            get: { coordinator.externalChange != nil },
            set: { if !$0 { coordinator.externalChange = nil } }
        )) {
            Button("重载远端版本") {
                let remote = coordinator.externalChange
                coordinator.externalChange = nil
                coordinator.applyRemote(action: .reload, remote: remote)
            }
            Button("保留本地版本") {
                coordinator.externalChange = nil
                coordinator.applyRemote(action: .keepLocal, remote: nil)
            }
            Button("合并（远端追加到本地）") {
                let remote = coordinator.externalChange
                coordinator.externalChange = nil
                coordinator.applyRemote(action: .merge, remote: remote)
            }
            Button("取消", role: .cancel) { coordinator.externalChange = nil }
        } message: {
            Text("检测到该笔记被其他设备修改。任一选择都不会静默覆盖另一方的修改。")
        }
        .alert("保存失败", isPresented: Binding(
            get: { coordinator.saveError != nil },
            set: { if !$0 { coordinator.saveError = nil } }
        )) {
            Button("好", role: .cancel) { coordinator.saveError = nil }
        } message: {
            Text(coordinator.saveError ?? "")
        }
    }
}

// MARK: - 模式条

struct VimModeBar: View {
    @ObservedObject var coordinator: EditorCoordinator
    @State private var exInput = ""
    @FocusState private var exFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(modeLabel)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(modeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(modeColor)
            if coordinator.mode == .exCommand {
                TextField("命令（回车执行）", text: $exInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($exFocused)
                    .onAppear { exInput = coordinator.exPrompt; exFocused = true }
                    .onSubmit {
                        coordinator.submitEx(exInput)
                        exInput = ""
                    }
            } else if !coordinator.message.isEmpty {
                Text(coordinator.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var modeLabel: String {
        switch coordinator.mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visualChar: return "VISUAL"
        case .visualLine: return "V-LINE"
        case .exCommand: return "命令"
        }
    }

    private var modeColor: Color {
        switch coordinator.mode {
        case .normal: return .blue
        case .insert: return .green
        case .visualChar, .visualLine: return .orange
        case .exCommand: return .purple
        }
    }

    private var hint: String {
        switch coordinator.mode {
        case .normal: return "i 插入 · : 命令 · / 搜索 · v 可视"
        case .insert: return "Esc 返回 NORMAL"
        default: return ""
        }
    }
}
