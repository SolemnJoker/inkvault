import Foundation

// MARK: - AST

/// 行内片段。
indirect enum Span: Equatable {
    case text(String)
    case bold([Span])
    case italic([Span])
    case strike([Span])
    case code(String)
    case link(url: String, spans: [Span])
    case autolink(String)
    /// [[target]] 或 [[target|alias]]
    case wiki(target: String, alias: String?)
    /// ![[target]]
    case embed(target: String)
    /// ![alt](path)
    case image(path: String, alt: String)
    /// 行内 $...$（display=false）与独立 $$...$$（display=true）
    case math(tex: String, display: Bool)
}

/// 块级节点。
indirect enum Block: Equatable {
    case heading(level: Int, spans: [Span])
    case paragraph(spans: [Span])
    case codeFence(lang: String?, text: String)
    case blockquote(children: [Block])
    case list(ordered: Bool, tight: Bool, items: [ListItem])
    case table(header: [String], rows: [[String]])
    case hr
    /// YAML frontmatter 解析出的属性表（US-02）。
    case frontmatter(fields: [FrontmatterField])
}

struct ListItem: Equatable {
    /// nil = 普通列表项；true/false = 任务列表
    var checked: Bool?
    var spans: [Span]
    var children: [Block]

    init(checked: Bool? = nil, spans: [Span] = [], children: [Block] = []) {
        self.checked = checked
        self.spans = spans
        self.children = children
    }
}

/// frontmatter 属性表的键值对。
struct FrontmatterField: Equatable {
    var key: String
    var value: String
}

// MARK: - 解析器

/// 项目允许的扩展范围（D-02）：[[、![[、frontmatter、相对路径图片、Mermaid、KaTeX。
struct MarkdownParser {
    /// 返回（frontmatter 字段, 块列表）；frontmatter 为 nil 表示无或未闭合。
    static func parse(_ text: String) -> (frontmatter: [FrontmatterField]?, blocks: [Block]) {
        var lines = text.components(separatedBy: "\n")
        var frontmatter: [FrontmatterField]?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var fields: [FrontmatterField] = []
            var i = 1
            var closed = false
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
                if let sep = l.firstIndex(of: ":") {
                    let key = String(l[..<sep]).trimmingCharacters(in: .whitespaces)
                    let value = String(l[l.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { fields.append(FrontmatterField(key: key, value: value)) }
                }
                i += 1
            }
            if closed {
                frontmatter = fields
                lines.removeSubrange(0...i)
            }
        }
        return (frontmatter, parseBlocks(lines))
    }

    // MARK: 块级

    static func parseBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // 代码围栏
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                i = min(i + 1, lines.count) // 跳过闭合围栏
                blocks.append(.codeFence(lang: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                continue
            }

            // 标题
            if trimmed.hasPrefix("#"), let hashEnd = trimmed.firstIndex(where: { $0 != "#" }) {
                let level = trimmed.distance(from: trimmed.startIndex, to: hashEnd)
                if level <= 6 {
                    let after = trimmed.index(after: hashEnd)
                    let rest = String(trimmed[after...]).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, spans: parseSpans(rest)))
                    i += 1
                    continue
                }
            }

            // 分隔线
            if isHR(trimmed) { blocks.append(.hr); i += 1; continue }

            // 引用
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        inner.append(String(t.dropFirst(t.hasPrefix("> ") ? 2 : 1)))
                        i += 1
                    } else if !t.isEmpty {
                        inner.append(t); i += 1
                    } else { break }
                }
                blocks.append(.blockquote(children: parseBlocks(inner)))
                continue
            }

            // 表格：当前行含 |，且下一行是分隔行
            if trimmed.contains("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
                let header = splitTableRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitTableRow(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 列表（有序/无序/任务），支持一级嵌套
            if let itemMarker = listMarker(trimmed) {
                let (ordered, markerLen) = itemMarker
                var items: [ListItem] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let line = lines[i]
                    let lead = line.count - line.drop(while: { $0 == " " }).count
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard let m = listMarker(t), lead <= 4 else {
                        // 列表后的普通段落结束列表
                        break
                    }
                    let (o, len) = m
                    var content = String(t.dropFirst(len)).trimmingCharacters(in: .whitespaces)
                    var checked: Bool?
                    if content.hasPrefix("[ ] ") || content == "[ ]" { checked = false; content = String(content.dropFirst(content.hasPrefix("[ ] ") ? 4 : 3)).trimmingCharacters(in: .whitespaces) }
                    else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") || content == "[x]" || content == "[X]" { checked = true; content = String(content.dropFirst(content.hasPrefix("[x] ") || content.hasPrefix("[X] ") ? 4 : 3)).trimmingCharacters(in: .whitespaces) }
                    // 收集嵌套子行
                    var sub: [String] = []
                    while i + 1 < lines.count {
                        let next = lines[i + 1]
                        let nextLead = next.count - next.drop(while: { $0 == " " }).count
                        if nextLead > 0, !next.trimmingCharacters(in: .whitespaces).isEmpty {
                            sub.append(String(next.dropFirst(nextLead)))
                            i += 1
                        } else { break }
                    }
                    items.append(ListItem(checked: checked, spans: parseSpans(content), children: sub.isEmpty ? [] : parseBlocks(sub)))
                    if ordered != o { break }
                    i += 1
                }
                blocks.append(.list(ordered: ordered, tight: true, items: items))
                continue
            }

            // 段落：合并后续非空、非结构行
            var para: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || listMarker(t) != nil || (t.contains("|") && i + 1 < lines.count && isTableDivider(lines[i + 1])) {
                    break
                }
                para.append(t); i += 1
            }
            blocks.append(.paragraph(spans: parseSpans(para.joined(separator: "\n"))))
        }
        return blocks
    }

    private static func isHR(_ s: String) -> Bool {
        let set = Set(s)
        if set.isSubset(of: ["-", " "]) && s.contains("-") { return s.split(separator: " ").joined().count >= 3 }
        if set.isSubset(of: ["*", " "]) && s.contains("*") { return s.split(separator: " ").joined().count >= 3 }
        return false
    }

    private static func isTableDivider(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return Set(t).isSubset(of: ["|", "-", ":", " "])
    }

    private static func splitTableRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listMarker(_ s: String) -> (ordered: Bool, length: Int)? {
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { return (false, 2) }
        // 有序：数字. 或 数字)
        for (i, c) in s.enumerated() {
            if c.isNumber { continue }
            if (c == "." || c == ")") && i > 0, s.count > i + 1, s[s.index(s.startIndex, offsetBy: i + 1)] == " " {
                return (true, i + 2)
            }
            return nil
        }
        return nil
    }

    // MARK: 行内

    static func parseSpans(_ text: String) -> [Span] {
        parseInline(Array(text))
    }

    private static func parseInline(_ chars: [Character]) -> [Span] {
        var spans: [Span] = []
        var buffer = ""
        var i = 0
        func flush() {
            if !buffer.isEmpty { spans.append(.text(buffer)); buffer = "" }
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "`":
                flush()
                // 代码 span
                var j = i + 1
                var code = ""
                while j < chars.count, chars[j] != "`" { code.append(chars[j]); j += 1 }
                if j < chars.count {
                    spans.append(.code(code))
                    i = j + 1
                } else {
                    buffer.append("`"); i += 1
                }
            case "*", "_":
                // 粗体/斜体
                let isBold = i + 1 < chars.count && chars[i + 1] == c
                let marker = isBold ? 2 : 1
                let closeIdx = findInlineClose(chars, from: i + marker, marker: String(repeating: c, count: marker))
                if let close = closeIdx {
                    let inner = Array(chars[(i + marker)..<close])
                    let innerSpans = parseInline(inner)
                    flush()
                    spans.append(isBold ? .bold(innerSpans) : .italic(innerSpans))
                    i = close + marker
                } else {
                    buffer.append(c); i += 1
                }
            case "~":
                if i + 1 < chars.count, chars[i + 1] == "~",
                   let close = findInlineClose(chars, from: i + 2, marker: "~~") {
                    let inner = parseInline(Array(chars[(i + 2)..<close]))
                    flush(); spans.append(.strike(inner)); i = close + 2
                } else { buffer.append(c); i += 1 }
            case "!":
                // ![[embed]] 或 ![alt](path)
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    if i + 2 < chars.count, chars[i + 2] == "[",
                       let close = findWikiClose(chars, from: i + 3) {
                        let inner = String(chars[(i + 3)..<close])
                        flush(); spans.append(.embed(target: inner)); i = close + 2
                    } else if let close = findInlineClose(chars, from: i + 2, marker: "]") {
                        let alt = String(chars[(i + 2)..<close])
                        // 寻找 (path)
                        var j = close + 1
                        if j < chars.count, chars[j] == "(" {
                            var path = ""
                            j += 1
                            while j < chars.count, chars[j] != ")" { path.append(chars[j]); j += 1 }
                            if j < chars.count {
                                flush(); spans.append(.image(path: path, alt: alt)); i = j + 1
                            } else { buffer.append(c); i += 1 }
                        } else { buffer.append(c); i += 1 }
                    } else { buffer.append(c); i += 1 }
                } else { buffer.append(c); i += 1 }
            case "[":
                if i + 1 < chars.count, chars[i + 1] == "[",
                   let close = findWikiClose(chars, from: i + 2) {
                    let inner = String(chars[(i + 2)..<close])
                    // [[target|alias]]：按第一个 | 拆分
                    let parts = inner.components(separatedBy: "|")
                    if parts.count >= 2 {
                        flush(); spans.append(.wiki(target: parts[0], alias: parts[1])); i = close + 2
                    } else {
                        flush(); spans.append(.wiki(target: inner, alias: nil)); i = close + 2
                    }
                } else if let close = findInlineClose(chars, from: i + 1, marker: "]") {
                    let label = String(chars[(i + 1)..<close])
                    var j = close + 1
                    if j < chars.count, chars[j] == "(" {
                        var url = ""
                        j += 1
                        while j < chars.count, chars[j] != ")" { url.append(chars[j]); j += 1 }
                        if j < chars.count {
                            flush(); spans.append(.link(url: url, spans: parseSpans(label))); i = j + 1
                        } else { buffer.append(c); i += 1 }
                    } else { buffer.append(c); i += 1 }
                } else { buffer.append(c); i += 1 }
            case "$":
                if i + 1 < chars.count, chars[i + 1] == "$",
                   let close = findInlineClose(chars, from: i + 2, marker: "$$") {
                    let inner = String(chars[(i + 2)..<close])
                    if !inner.isEmpty {
                        flush(); spans.append(.math(tex: inner, display: true)); i = close + 2
                    } else { buffer.append(c); i += 2 }
                } else if i + 1 < chars.count, !isSpace(chars[i + 1]),
                          let close = findMathClose(chars, from: i + 2) {
                    let inner = String(chars[(i + 1)..<close])
                    if !inner.isEmpty, let last = inner.last, !isSpace(last) {
                        flush(); spans.append(.math(tex: inner, display: false)); i = close + 1
                    } else { buffer.append(c); i += 1 }
                } else { buffer.append(c); i += 1 }
            case "h":
                // 自动链接 http:// https://
                if i + 7 < chars.count || (i + 6 < chars.count) {
                    let rest = String(chars[i...].prefix(8)).lowercased()
                    if rest.hasPrefix("https://") || rest.hasPrefix("http://") {
                        var url = ""
                        var j = i
                        while j < chars.count, !isURLBreak(chars[j]) { url.append(chars[j]); j += 1 }
                        flush(); spans.append(.autolink(url)); i = j
                    } else { buffer.append(c); i += 1 }
                } else { buffer.append(c); i += 1 }
            default:
                buffer.append(c); i += 1
            }
        }
        flush()
        return spans
    }

    private static func findInlineClose(_ chars: [Character], from: Int, marker: String) -> Int? {
        let m = Array(marker)
        guard !m.isEmpty else { return nil }
        var i = from
        while i < chars.count {
            if i + m.count <= chars.count, Array(chars[i..<(i + m.count)]) == m {
                return i
            }
            i += 1
        }
        return nil
    }

    /// [[...]] 的闭合：容忍一层内部 [，遇 ]] 结束；遇换行视为未闭合。
    private static func findWikiClose(_ chars: [Character], from: Int) -> Int? {
        var i = from
        while i + 1 < chars.count {
            if chars[i] == "]" && chars[i + 1] == "]" { return i }
            if chars[i] == "\n" { return nil }
            i += 1
        }
        return nil
    }

    /// 行内数学闭合 $：跳过 $ 前为空格的位置，遇换行放弃
    private static func findMathClose(_ chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == "$" {
                if i == 0 || !isSpace(chars[i - 1]) { return i }
            }
            if chars[i] == "
" { return nil }
            i += 1
        }
        return nil
    }

    private static func isURLBreak(_ c: Character) -> Bool {
        c == " " || c == ")" || c == "]" || c == "\n" || c == "<"
    }
}

extension Span {
    /// 提取纯文本（用于搜索、预览等）。
    var plainText: String {
        switch self {
        case .text(let s): return s
        case .code(let s): return s
        case .autolink(let s): return s
        case .bold(let inner), .italic(let inner), .strike(let inner):
            return inner.map { $0.plainText }.joined()
        case .link(_, let inner):
            return inner.map { $0.plainText }.joined()
        case .wiki(let target, let alias): return alias ?? target
        case .embed(let target): return target
        case .image(_, let alt): return alt
        case .math(let tex, _): return tex
        }
    }
}
