import SwiftUI

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
        List {
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

            Section("文件") {
                if let session = model.session {
                    OutlineGroup(makeTree(session: session, relative: ""), children: \.children) { node in
                        FileRow(node: node)
                    }
                }
            }
        }
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
                            children: [])
        }
        return FileNode(name: relative, path: relative, isDirectory: true, hasConflict: false, children: children)
    }
}

struct FileNode: Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var hasConflict: Bool
    var children: [FileNode]

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
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked: (url: URL, bookmark: Data)?
    @State private var pickerActive = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        pickerActive = true
                    } label: {
                        Label("选择笔记库文件夹", systemImage: "folder")
                    }
                    if let picked {
                        Text(picked.url.lastPathComponent).font(.headline)
                    }
                } header: {
                    Text("选择你已有的 Obsidian vault 目录")
                } footer: {
                    Text("App 直接读写该目录，不产生副本；.obsidian/ 等配置保持只读。")
                }
            }
            .navigationTitle("添加笔记库")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开") {
                        guard let picked else { return }
                        let record = model.registry.add(name: picked.url.lastPathComponent, bookmarkData: picked.bookmark)
                        model.openVault(record)
                        dismiss()
                    }
                    .disabled(picked == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .fileImporter(isPresented: $pickerActive, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    // 访问权有效期内生成 security-scoped bookmark（US-01）
                    if let bookmark = try? url.bookmarkData() {
                        picked = (url, bookmark)
                    }
                }
            }
        }
    }
}
