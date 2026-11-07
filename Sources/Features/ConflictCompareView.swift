import SwiftUI

/// 冲突对比与取舍（US-08）：并排显示本地/远端，选择保留本地、远端或都保留。
struct ConflictCompareView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pair: ConflictPair
    @State private var localText = ""
    @State private var remoteText = ""
    @State private var resolving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    versionPane(title: "本地版本", text: localText, tint: .blue)
                    versionPane(title: "远端版本", text: remoteText, tint: .orange)
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle(pair.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button {
                        resolve(.keepLocal)
                    } label: {
                        Label("保留本地", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        resolve(.keepRemote)
                    } label: {
                        Label("保留远端", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        resolve(.keepBoth)
                    } label: {
                        Label("都保留", systemImage: "plus.square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.bar)
                .disabled(resolving)
            }
            .task { loadContents() }
            .alert("处理失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func versionPane(title: String, text: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(tint.opacity(0.15))
            ScrollView {
                Text(text.isEmpty ? "（空）" : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func loadContents() {
        guard let service = model.conflictService else { return }
        let contents = service.loadContents(pair: pair)
        localText = contents.local
        remoteText = contents.remote.first?.text ?? ""
    }

    private func resolve(_ resolution: ConflictService.Resolution) {
        guard let service = model.conflictService else { return }
        resolving = true
        DispatchQueue.global().async {
            do {
                try service.resolve(pair: pair, resolution: resolution)
                DispatchQueue.main.async {
                    resolving = false
                    model.showToast("冲突已处理")
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    resolving = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
