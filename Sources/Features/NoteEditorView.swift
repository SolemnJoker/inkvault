import SwiftUI
import UIKit

// MARK: - UITextView 子类（编辑核心，D-03）

final class VimTextView: UITextView {
    var vim: VimEngine?
    var vimEnabled = false

    override var inputView: UIView? {
        get {
            // normal/visual/ex 模式隐藏软键盘（vim 语义），insert 恢复（US-05）
            if vimEnabled, let vim, vim.mode != .insert {
                return UIView(frame: .zero)
            }
            return super.inputView
        }
        set { super.inputView = newValue }
    }

    override var textInputMode: UITextInputMode? {
        // US-06（最佳努力）：normal 模式强制英文输入法，避免按键触发拼音候选
        if vimEnabled, let vim, vim.mode != .insert {
            if let en = UITextInputMode.activeInputModes.first(where: { ($0.primaryLanguage ?? "").hasPrefix("en") }) {
                return en
            }
        }
        return super.textInputMode
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard vimEnabled, let vim, vim.mode != .insert else {
            super.pressesBegan(presses, with: event)
            return
        }
        var consumed = false
        for press in presses {
            guard let key = press.key, let vimKey = Self.mapKey(key) else { continue }
            vim.key(vimKey)
            consumed = true
        }
        if consumed {
            coordinator?.refreshFromEngine()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard vimEnabled, let vim, vim.mode != .insert else {
            super.pressesEnded(presses, with: event)
            return
        }
        let mapped = presses.contains { $0.key != nil && Self.mapKey($0.key!) != nil }
        if !mapped { super.pressesEnded(presses, with: event) }
    }

    weak var coordinator: EditorCoordinator?

    static func mapKey(_ key: UIKey) -> VimEngine.Key? {
        if key.keyCode == .keyboardEscape { return .escape }
        if key.keyCode == .keyboardReturn { return .enter }
        if key.keyCode == .keyboardDeleteOrBackspace { return .backspace }
        let mods = key.modifierFlags
        if mods.contains(.control), key.keyCode == .keyboardR { return .ctrlR }
        guard mods.subtracting(.alphaShift).subtracting(.numericPad).isEmpty else { return nil }
        let chars = key.charactersIgnoringModifiers
        guard let first = chars.first else { return nil }
        return .char(first)
    }
}

// MARK: - 协调器（引擎接线 + 防抖保存 + 外部变更保护）

@MainActor
final class EditorCoordinator: NSObject, UITextViewDelegate, ObservableObject {
    let textView = VimTextView()
    let vim = VimEngine()
    let debouncer: Debouncer

    @Published var mode: VimEngine.Mode = .normal
    @Published var message = ""
    @Published var exPrompt = ""
    @Published var externalChange: String?
    @Published var saveError: String?

    private var currentPath = ""
    private var loadedContent = ""
    private var baseline = FileStamp.zero
    private var highlightPending = false

    struct FileStamp: Equatable {
        var size: Int
        var modified: Date?
        static let zero = FileStamp(size: -1, modified: nil)
    }

    override init() {
        debouncer = Debouncer(interval: 1.0) // 默认 1s，可配（D-10）
        super.init()
        textView.delegate = self
        textView.vim = vim
        textView.vimEnabled = UserDefaults.standard.object(forKey: "vimEnabled") as? Bool ?? true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        textView.backgroundColor = .systemBackground
        textView.coordinator = self
        EditorSaveHub.shared.register(ObjectIdentifier(self), debouncer)
    }

    deinit {
        EditorSaveHub.shared.unregister(ObjectIdentifier(self))
    }

    // MARK: 装载

    func load(path: String, content: String) {
        guard path != currentPath || content != loadedContent else { return }
        debouncer.flush()
        currentPath = path
        loadedContent = content
        vim.setText(content, cursorAtEnd: true)
        textView.text = content
        baseline = stampNow()
        refreshFromEngine()
        scheduleHighlight()
    }

    /// 防抖窗口内切走前强制落盘（D-10）。
    func flushPendingSave() { debouncer.flush() }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        guard vim.mode == .insert else { return }
        let ns = textView.text as NSString
        let (line, col) = Self.lineCol(for: textView.selectedRange.location, in: ns)
        vim.syncFromText(textView.text, cursorLine: line, cursorCol: col)
        // 防抖时长可配（D-10：800–2000ms，设置页调整）
        let saved = UserDefaults.standard.double(forKey: "saveDebounceMs")
        if saved >= 800, saved <= 2000 { debouncer.interval = saved / 1000 }
        scheduleHighlight()
        debouncer.bounce { [weak self] in self?.save() }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard vim.mode == .insert else { return }
        let ns = textView.text as NSString
        let (line, col) = Self.lineCol(for: textView.selectedRange.location, in: ns)
        vim.syncFromText(textView.text, cursorLine: line, cursorCol: col)
    }

    // MARK: 引擎 → 视图

    func refreshFromEngine() {
        let newText = vim.text
        if newText != textView.text {
            textView.text = newText
        }
        textView.selectedRange = selectionRange()
        mode = vim.mode
        message = vim.message
        exPrompt = vim.exPrompt
        textView.reloadInputViews()
        scheduleHighlight()
        if vim.mode == .insert {
            textView.becomeFirstResponder()
        }
    }

    /// SwiftUI ex 输入提交（: 或 / ?）。
    func submitEx(_ input: String) {
        for c in input { vim.key(.char(c)) }
        vim.key(.enter)
        refreshFromEngine()
    }

    func appendExChar(_ c: Character) {
        vim.key(.char(c))
        refreshFromEngine()
    }

    // MARK: 外部变更三选（US-10）

    func applyRemote(action: EditorApply.Action, remote: String?) {
        switch action {
        case .reload:
            guard let remote else { return }
            vim.setText(remote, cursorAtEnd: false)
            textView.text = remote
            if let url = remoteURL() {
                try? VaultWriter.shared.write(remote, to: url)
            }
            loadedContent = remote
            baseline = stampNow()
        case .merge:
            guard let remote else { return }
            let merged = textView.text + "\n\n<!-- 远端版本（合并） -->\n" + remote
            vim.setText(merged, cursorAtEnd: false)
            textView.text = merged
            save(force: true)
        case .keepLocal:
            save(force: true) // 以本地内容覆盖，忽略基线检查（用户明确选择）
        }
        refreshFromEngine()
    }

    // MARK: 保存

    private func remoteURL() -> URL? {
        AppModelHolderBridge.session?.absoluteURL(for: currentPath)
    }

    private func save(force: Bool = false) {
        guard !currentPath.isEmpty, let url = remoteURL() else { return }
        let now = stampNow()
        if !force, now != baseline {
            // US-10：外部修改，绝不静默覆盖
            let remote = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            externalChange = remote
            return
        }
        do {
            try VaultWriter.shared.write(textView.text, to: url)
            loadedContent = textView.text
            baseline = stampNow()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func stampNow() -> FileStamp {
        guard let url = remoteURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return .zero }
        return FileStamp(size: attrs[.size] as? Int ?? -1, modified: attrs[.modificationDate] as? Date)
    }

    // MARK: 选区换算

    private func selectionRange() -> NSRange {
        let ns = textView.text as NSString
        func offset(line: Int, col: Int) -> Int {
            var off = 0
            let lines = ns.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                if i == line { return off + min(col, (l as NSString).length) }
                off += (l as NSString).length + 1
            }
            return off
        }
        if (vim.mode == .visualChar || vim.mode == .visualLine), let r = vim.visualRange() {
            let start = offset(line: r.start.line, col: r.start.col)
            if vim.mode == .visualLine {
                let end = offset(line: min(r.end.line + 1, ns.components(separatedBy: "\n").count - 1), col: 0)
                return NSRange(location: start, length: max(0, end - start))
            }
            let end = offset(line: r.end.line, col: r.end.col + 1)
            return NSRange(location: start, length: max(0, end - start))
        }
        return NSRange(location: offset(line: vim.cursor.line, col: vim.cursor.col), length: 0)
    }

    static func lineCol(for offset: Int, in text: NSString) -> (Int, Int) {
        var line = 0
        var col = 0
        var i = 0
        let total = min(offset, text.length)
        while i < total {
            if text.character(at: i) == 0x0A { line += 1; col = 0 } else { col += 1 }
            i += 1
        }
        return (line, col)
    }

    // MARK: 高亮（异步，NFR-02：击键路径不做重活）

    private func scheduleHighlight() {
        guard !highlightPending else { return }
        highlightPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.highlightPending = false
            EditorHighlighter.apply(to: self.textView, text: self.textView.text)
        }
    }
}

struct EditorApply {
    enum Action { case reload, merge, keepLocal }
}

/// AppModel 弱引用桥（representable 层拿 session）。
@MainActor
enum AppModelHolderBridge {
    static weak var session: VaultSession?
}

// MARK: - Representable

struct NoteEditorView: UIViewRepresentable {
    let coordinator: EditorCoordinator

    func makeUIView(context: Context) -> VimTextView {
        coordinator.textView
    }

    func updateUIView(_ tv: VimTextView, context: Context) {}
}

// MARK: - 编辑器语法高亮（轻量正则）

enum EditorHighlighter {
    static func apply(to tv: UITextView, text: String) {
        guard text.utf16.count < 400_000 else { return } // 超长降级保击键性能
        let ns = text as NSString
        let storage = tv.textStorage
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: UIColor.label,
        ], range: full)
        for (pattern, attrs) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            re.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m else { return }
                storage.addAttributes(attrs, range: m.range)
            }
        }
        storage.endEditing()
    }

    private static let patterns: [(String, [NSAttributedString.Key: Any])] = [
        ("^#{1,6} .*$", [.font: UIFont.monospacedSystemFont(ofSize: 17, weight: .bold), .foregroundColor: UIColor.systemBlue]),
        ("^> .*$", [.foregroundColor: UIColor.secondaryLabel]),
        ("^```.*$", [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.systemGray]),
        ("`[^`\n]+`", [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .backgroundColor: UIColor.systemGray6]),
        ("\\*\\*[^*\n]+\\*\\*", [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)]),
        ("\\[\\[[^\\]\n]+\\]\\]", [.foregroundColor: UIColor.systemBlue]),
        ("!\\[\\[[^\\]\n]+\\]\\]", [.foregroundColor: UIColor.systemTeal]),
        ("^\\s*[-*+] \\[[ xX]\\]", [.foregroundColor: UIColor.systemOrange]),
        ("\\$\\$[^$\n]+\\$\\$", [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.systemPurple]),
        ("\\$[^$\n]+\\$", [.foregroundColor: UIColor.systemPurple]),
        ("```mermaid", [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.systemIndigo]),
    ]
}
