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
            if model.mode == .editing {
                EditorScreen(path: path, initialContent: content)
            } else {
                ReadingView(path: path, content: content, baseDir: model.session?.rootURL, onWikiTap: { target in
                    navigate(target: target)
                })
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.mode = model.mode == .reading ? .editing : .reading
                } label: {
                    Image(systemName: model.mode == .reading ? "square.and.pencil" : "book")
                }
            }
        }
        .task { load() }
        .onChange(of: path) { _, _ in
            if model.mode == .editing { model.mode = .reading }
            load()
        }
        .alert("无法读取笔记", isPresented: $loadFailed) {} message: {
            Text("文件不存在或无法访问。")
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
        guard let en = FileManager.default.enumerator(at: root, options: []) else { return nil }
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
        guard context.coordinator.renderedPath != path || context.coordinator.renderedContent != content else { return }
        context.coordinator.renderedPath = path
        context.coordinator.renderedContent = content
        context.coordinator.onWikiTap = onWikiTap
        tv.attributedText = ReadingRenderer.render(text: content, baseDir: baseDir, maxWidth: tv.bounds.width)
        tv.setContentOffset(.zero, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onWikiTap: onWikiTap) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var renderedPath: String?
        var renderedContent: String?
        var onWikiTap: (String) -> Void

        init(onWikiTap: @escaping (String) -> Void) {
            self.onWikiTap = onWikiTap
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
