import SwiftUI
import os

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var registry = VaultRegistry.shared

    var body: some View {
        Group {
            if registry.vaults.isEmpty {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    detailView
                }
            }
        }
        .sheet(isPresented: $model.showAddVault) { AddVaultSheet() }
        .sheet(isPresented: $model.showSyncScreen) { SyncScreen() }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(item: $model.showConflictCompare) { pair in
            ConflictCompareView(pair: pair)
        }
        .alert("无法访问笔记库", isPresented: $model.vaultAuthorizationLost) {
            Button("重新授权") { model.showAddVault = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目录可能已被移动或权限失效。请重新选择该笔记库位置；未保存的内容在重新授权后仍可继续。")
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }

    @ViewBuilder
    private var detailView: some View {
        if let path = model.selectedPath {
            NoteScreen(path: path)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("选择一篇笔记开始阅读")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 首次使用

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "book")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
            Text("InkVault").font(.largeTitle.bold())
            Text("直接打开你已有的 Obsidian 笔记库，\n不做复制、不污染配置。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                model.showAddVault = true
            } label: {
                Label("打开笔记库", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 侧栏（vault 切换 + 文件树 + 搜索 + 冲突入口）

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var registry = VaultRegistry.shared
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        sidebarList
            .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "搜索文件名或内容")
        .onAppear {
            // 冲突标记随同步更新（US-08）
            model.conflictService?.rescan()
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            guard !newValue.isEmpty else { searchResults = []; return }
            guard let session = model.session else { return }
            let service = SearchService(session: session)
            searchTask = Task {
                let r = await service.search(newValue)
                if !Task.isCancelled { searchResults = r }
            }
        }
        .overlay {
            if !searchText.isEmpty {
                searchResultList
            }
        }
        .navigationTitle(model.registry.currentVault?.name ?? "InkVault")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showSyncScreen = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    private var sidebarList: some View {
        List {
            vaultSection
            conflictFilesSection
            filesSection
        }
    }

    private var vaultSection: some View {
        Section("笔记库") {
            ForEach(model.registry.vaults) { vault in
                Button {
                    model.switchVault(vault.id)
                } label: {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text(vault.name).lineLimit(1)
                        if vault.id == model.registry.currentVaultID { Spacer(); Image(systemName: "checkmark") }
                    }
                }
                .tint(.primary)
            }
            Button {
                model.showAddVault = true
            } label: {
                Label("添加笔记库", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private var conflictFilesSection: some View {
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

    @ViewBuilder
    private var filesSection: some View {
        Section("文件") {
            if let session = model.session {
                OutlineGroup(makeTree(session: session, relative: ""), children: \.children) { node in
                    FileRow(node: node)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultList: some View {
        List(searchResults) { result in
            Button {
                model.selectedPath = result.path
                model.mode = .reading
                searchText = ""
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(result.name)
                        if result.matchType == .filename {
                            Text("文件名").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    if let s = result.snippet {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(result.path).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        }
        .scrollContentBackground(.visible)
    }

    private func makeTree(session: VaultSession, relative: String) -> FileNode {
        let entries = session.listDirectory(relative: relative)
        let conflicts = model.conflictService?.pairs ?? []
        let conflictOrigins = Set(conflicts.map(\.originalPath))
        let children = entries.map { entry -> FileNode in
            if entry.isDirectory {
                return makeTree(session: session, relative: entry.path).prefixed(name: entry.name)
            }
            return FileNode(name: entry.name, path: entry.path, isDirectory: false,
                            hasConflict: conflictOrigins.contains(entry.path),
                            children: nil)
        }
        return FileNode(name: relative, path: relative, isDirectory: true, hasConflict: false, children: children.isEmpty ? nil : children)
    }
}

struct FileNode: Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var hasConflict: Bool
    var children: [FileNode]?

    func prefixed(name: String) -> FileNode {
        FileNode(name: name, path: path, isDirectory: true, hasConflict: false, children: children)
    }
}

struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let node: FileNode

    var body: some View {
        if node.isDirectory {
            Label(node.name, systemImage: "folder")
        } else {
            Button {
                model.selectedPath = node.path
                model.mode = .reading
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text(node.name).lineLimit(1)
                    if node.hasConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .tint(.primary)
        }
    }
}

struct AddVaultSheet: View {
    static let logger = Logger(subsystem: "com.inkvault.app", category: "vault")

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked: (url: URL, bookmark: Data)?
    @State private var pickerActive = false
    @State private var copyMode = false
    @State private var vaultDetected = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        copyMode = false
                        pickerActive = true
                    } label: {
                        Label("选择笔记库文件夹", systemImage: "folder")
                    }
                    Button {
                        copyMode = true
                        pickerActive = true
                    } label: {
                        Label("诊断：导入副本模式选择", systemImage: "stethoscope")
                    }
                    if let picked {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: vaultDetected ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(vaultDetected ? Color.green : Color.orange)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(picked.url.lastPathComponent).font(.headline)
                                Text(vaultDetected
                                     ? "已识别 Obsidian 库（发现 .obsidian）"
                                     : "未发现 .obsidian —— 可能不是库根目录。仍可打开，但若库在 Obsidian App 内部则无法这样选择。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("选择你已有的 Obsidian vault 目录")
                } footer: {
                    Text("在文件选择器的「浏览」侧边栏里，Obsidian、iCloud 都是可选位置（Obsidian 已把内部存储暴露给系统文件 App，Möbius Sync 走的也是这条通道）。「浏览 → 我的 iPad → Obsidian」进入后选择你的库文件夹即可。App 直接读写所选目录，不产生副本，.obsidian/ 保持只读。")
                }
            }
            .navigationTitle("添加笔记库")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开") {
                        guard let picked else { return }
                        Self.logger.info("打开 vault: \(picked.url.lastPathComponent, privacy: .public), detected=\(vaultDetected)")
                        let record = model.registry.add(name: picked.url.lastPathComponent, bookmarkData: picked.bookmark)
                        model.openVault(record)
                        if model.vaultAuthorizationLost {
                            errorMsg = "目录授权解析失败（\(picked.url.lastPathComponent)）。请重试选择，或把库移动到「文件」可见的位置后重试。"
                            model.registry.remove(record.id)
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(picked == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $pickerActive) {
                // SwiftUI fileImporter 对第三方 App 位置（如 Obsidian）里的目录选择有已知缺陷：
                // 「打开」无响应。改用 UIKit UIDocumentPickerViewController，全屏呈现排除 sheet 呈现干扰。
                FolderPicker(onPick: { url in
                    handlePicked(url: url)
                }, asCopy: copyMode)
                .ignoresSafeArea()
            }
            .alert("添加失败", isPresented: Binding(
                get: { errorMsg != nil },
                set: { if !$0 { errorMsg = nil } }
            )) {
                Button("好", role: .cancel) { errorMsg = nil }
            } message: {
                Text(errorMsg ?? "")
            }
        }
    }

    private func logRuntimeFlags() {
        let info = Bundle.main.infoDictionary ?? [:]
        let ls = info["LSSupportsOpeningDocumentsInPlace"] ?? "(缺)"
        let browser = info["UISupportsDocumentBrowser"] ?? "(缺)"
        Self.logger.info("装机实际值: LS=\(ls, privacy: .public), DocBrowser=\(browser, privacy: .public), bundle=\(Bundle.main.bundleIdentifier ?? "-", privacy: .public)")
    }

    private func handlePicked(url: URL) {
        pickerActive = false
        Self.logger.info("handlePicked 进入, copyMode=\(copyMode), got=\(url.lastPathComponent, privacy: .public)")
        logRuntimeFlags()
        if copyMode {
            // 诊断路径：导入模式（系统把目录复制进我们沙盒）。能到这说明授权机制本身通，
            // 失败仅在"就地打开"路径 —— 指向签名/授权问题。
            errorMsg = "诊断成功：导入模式可以拿到目录（\(url.lastPathComponent)）。问题锁定在『就地打开』授权路径（签名相关）。"
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData()
            let marker = url.appendingPathComponent(".obsidian")
            vaultDetected = FileManager.default.fileExists(atPath: marker.path)
            picked = (url, bookmark)
            Self.logger.info("已选择目录 \(url.lastPathComponent, privacy: .public), bookmark ok, vaultDetected=\(vaultDetected)")
        } catch {
            Self.logger.error("bookmark 失败: \(error.localizedDescription, privacy: .public)")
            errorMsg = "生成访问书签失败：\(error.localizedDescription)。请重试；若反复失败，请把库移动到「文件」App 可见的位置。"
        }
    }
}

/// UIKit 目录选择器：绕开 SwiftUI fileImporter 对第三方位置目录「打开」无响应的缺陷。
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var asCopy: Bool = false

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        AddVaultSheet.logger.info("FolderPicker 即将呈现, asCopy=\(asCopy)")
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: asCopy)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            AddVaultSheet.logger.info("delegate 命中 didPick: \(urls.map({ $0.lastPathComponent }), privacy: .public)")
            onPick(urls[0])
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            AddVaultSheet.logger.info("delegate 命中 cancel")
        }
    }
}
