import SwiftUI
import UIKit

/// 一个笔记的阅读/编辑容器。
struct NoteScreen: View {
    @EnvironmentObject private var model: AppModel
    let path: String
    @State private var content = ""
    @State private var loadFailed = false

    var body: some View {
        Group {
            switch model.mode {
            case .reading:
                ReadingView(path: path, content: content, baseDir: model.session?.rootURL, onWikiTap: { target in
                    navigate(target: target)
                })
            case .editing:
                EditorScreen(path: path, initialContent: content, isSplit: false, onWikiTap: { target in
                    navigate(target: target)
                })
            case .split:
                EditorScreen(path: path, initialContent: content, isSplit: true, onWikiTap: { target in
                    navigate(target: target)
                })
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("查看方式", selection: $model.mode) {
                        Label("阅读", systemImage: "book").tag(NoteMode.reading)
                        Label("编辑", systemImage: "square.and.pencil").tag(NoteMode.editing)
                        Label("分屏实时预览", systemImage: "square.leftthird.inset.filled").tag(NoteMode.split)
                    }
                } label: {
                    Image(systemName: modeIcon)
                }
            }
        }
        .task { load() }
        .onChange(of: path) { _, _ in
            if model.mode != .reading { model.mode = .reading }
            load()
        }
        .alert("无法读取笔记", isPresented: $loadFailed) {} message: {
            Text("文件不存在或无法访问。")
        }
    }

    private var modeIcon: String {
        switch model.mode {
        case .reading: return "book"
        case .editing: return "square.and.pencil"
        case .split: return "square.leftthird.inset.filled"
        }
    }

    private func load() {
        guard let url = model.session?.absoluteURL(for: path) else { return }
        do {
            content = try String(contentsOf: url, encoding: .utf8)
            loadFailed = false
        } catch {
            loadFailed = true
            content = ""
        }
    }

    /// [[wikilink]] 解析：在库内按文件名模糊匹配（US-02）。
    private func navigate(target: String) {
        guard let root = model.session?.rootURL else { return }
        let clean = target.split(separator: "#").first.map(String.init) ?? target
        let wanted = clean.hasSuffix(".md") ? clean : clean + ".md"
        if let hit = findFile(named: wanted, under: root, limit: 20000) {
            let relative = hit.path.hasPrefix(root.path + "/") ? String(hit.path.dropFirst(root.path.count + 1)) : hit.path
            model.mode = .reading
            model.selectedPath = relative
        } else {
            model.showToast("未找到笔记：\(clean)")
        }
    }

    private func findFile(named name: String, under root: URL, limit: Int) -> URL? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return nil }
        var count = 0
        for case let url as URL in en {
            count += 1
            if count > limit { break }
            if VaultInternal.isHiddenName(url.lastPathComponent) { en.skipDescendants(); continue }
            if url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame, !url.hasDirectoryPath {
                return url
            }
        }
        return nil
    }
}

// MARK: - 阅读视图

struct ReadingView: UIViewRepresentable {
    let path: String
    let content: String
    var baseDir: URL?
    var onWikiTap: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        tv.backgroundColor = .systemBackground
        tv.delegate = context.coordinator
        tv.linkTextAttributes = [.foregroundColor: UIColor.systemBlue, .underlineStyle: 0]
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let pathChanged = context.coordinator.renderedPath != path
        guard pathChanged || context.coordinator.renderedContent != content else { return }
        context.coordinator.renderedPath = path
        context.coordinator.renderedContent = content
        context.coordinator.onWikiTap = onWikiTap
        // 换笔记即换 token：旧的异步渲染结果一律丢弃（不常驻）
        context.coordinator.newRenderToken()
        var pending: [PendingDiagram] = []
        tv.attributedText = ReadingRenderer.render(text: content, baseDir: baseDir, maxWidth: tv.bounds.width) { item in
            pending.append(item)
        }
        // 只在换笔记时回到顶部；实时预览刷新保持用户滚动位置
        if pathChanged {
            tv.setContentOffset(.zero, animated: false)
        }
        context.coordinator.flushDiagrams(textView: tv, items: pending)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onWikiTap: onWikiTap) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var renderedPath: String?
        var renderedContent: String?
        var onWikiTap: (String) -> Void
        private var renderToken = UUID()

        init(onWikiTap: @escaping (String) -> Void) {
            self.onWikiTap = onWikiTap
        }

        func newRenderToken() {
            renderToken = UUID()
        }

        /// 把占位条目交给离屏渲染引擎；完成后在主线程回填 attachment（D-01 例外管线）。
        func flushDiagrams(textView: UITextView, items: [PendingDiagram]) {
            guard !items.isEmpty else { return }
            let token = renderToken
            let maxWidth = max(200, textView.bounds.width - 32)
            for item in items {
                DiagramRenderEngine.shared.render(kind: item.kind, code: item.code, itemID: item.itemID) { [weak self, weak textView] result in
                    DispatchQueue.main.async {
                        guard let self, let textView, self.renderToken == token else { return } // 已换页/已销毁
                        let storage = textView.textStorage
                        let full = NSRange(location: 0, length: storage.length)
                        var ranges: [NSRange] = []
                        storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
                            if let att = value as? DiagramAttachment, att.itemID == item.itemID {
                                ranges.append(range)
                            }
                        }
                        guard !ranges.isEmpty else { return }
                        item.attachment.image = result.image
                        if result.error == nil, result.size.width > 4 {
                            let fit = min(result.size.width, maxWidth)
                            let scale = fit / result.size.width
                            item.attachment.bounds = CGRect(
                                x: 0,
                                y: item.kind == .math ? -3 : -6,
                                width: result.size.width * scale,
                                height: result.size.height * scale
                            )
                        }
                        storage.beginEditing()
                        for r in ranges {
                            storage.edited(.editedAttributes, range: r, changeInLength: 0)
                        }
                        storage.endEditing()
                    }
                }
            }
        }

        func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if url.scheme == ReadingRenderer.wikiScheme {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let target = comps?.queryItems?.first(where: { $0.name == "target" })?.value ?? url.lastPathComponent
                onWikiTap(target)
                return false
            }
            return true
        }
    }
}

extension AppModel {
    // 供 representable 层复用（占位：当前无额外扩展）
}
