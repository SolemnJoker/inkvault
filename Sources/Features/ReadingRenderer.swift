import UIKit

/// AST → NSAttributedString（原生文本路径，D-01：禁 WebView）。
/// wikilink 用自定义 scheme 便于 UITextView 链接交互；图片用 TextAttachment。
enum ReadingRenderer {
    static let wikiScheme = "inkvault-wiki"

    static func render(text: String, baseDir: URL?, maxWidth: CGFloat) -> NSAttributedString {
        let (frontmatter, blocks) = MarkdownParser.parse(text)
        let out = NSMutableAttributedString()

        if let fields = frontmatter {
            out.append(renderFrontmatter(fields))
        }
        for block in blocks {
            out.append(renderBlock(block, baseDir: baseDir, maxWidth: maxWidth, depth: 0))
        }
        return out
    }

    // MARK: 块级

    private static func renderBlock(_ block: Block, baseDir: URL?, maxWidth: CGFloat, depth: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch block {
        case .heading(let level, let spans):
            let sizes: [CGFloat] = [30, 26, 22, 19, 17, 16]
            let attr = renderSpans(spans, baseDir: baseDir)
            attr.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: sizes[max(0, min(5, level - 1))]), range: NSRange(location: 0, length: attr.length))
            attr.addAttribute(.paragraphStyle, value: para(spacingBefore: level == 1 ? 14 : 10, spacingAfter: 6), range: NSRange(location: 0, length: attr.length))
            out.append(attr)
            newline(out)
        case .paragraph(let spans):
            let attr = renderSpans(spans, baseDir: baseDir)
            attr.addAttribute(.paragraphStyle, value: para(spacingAfter: 8, lineSpacing: 3), range: NSRange(location: 0, length: attr.length))
            out.append(attr)
            newline(out)
        case .codeFence(_, let text):
            let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let body = NSMutableAttributedString(string: text + "\n", attributes: [
                .font: font,
                .backgroundColor: UIColor.systemGray6,
                .paragraphStyle: para(spacingBefore: 6, spacingAfter: 10, lineSpacing: 1),
            ])
            out.append(body)
        case .blockquote(let children):
            for child in children {
                let inner = renderBlock(child, baseDir: baseDir, maxWidth: maxWidth, depth: depth + 1)
                inner.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: NSRange(location: 0, length: inner.length))
                inner.addAttribute(.paragraphStyle, value: para(spacingAfter: 4, headIndent: 14, lineSpacing: 2), range: NSRange(location: 0, length: inner.length))
                out.append(inner)
            }
            newline(out)
        case .list(let ordered, _, let items):
            for (idx, item) in items.enumerated() {
                let bullet = ordered ? "\(idx + 1). " : "• "
                let prefix = NSMutableAttributedString(string: bullet, attributes: [.font: UIFont.systemFont(ofSize: 16)])
                let content = renderSpans(item.spans, baseDir: baseDir)
                content.addAttribute(.paragraphStyle, value: para(spacingAfter: 2, headIndent: 18, lineSpacing: 2), range: NSRange(location: 0, length: content.length))
                out.append(prefix); out.append(content); newline(out)
                for child in item.children {
                    let inner = renderBlock(child, baseDir: baseDir, maxWidth: maxWidth, depth: depth + 1)
                    inner.addAttribute(.paragraphStyle, value: para(spacingAfter: 2, headIndent: 32), range: NSRange(location: 0, length: inner.length))
                    out.append(inner)
                }
            }
            newline(out)
        case .table(let header, let rows):
            out.append(renderTable(header: header, rows: rows))
        case .hr:
            out.append(NSMutableAttributedString(string: "──────────", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .light),
                .foregroundColor: UIColor.tertiaryLabel,
            ]))
            newline(out)
        case .frontmatter(let fields):
            out.append(renderFrontmatter(fields))
        }
        return out
    }

    private static func renderFrontmatter(_ fields: [(key: String, value: String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard !fields.isEmpty else { return out }
        out.append(NSAttributedString(string: "属性\n", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 13),
            .foregroundColor: UIColor.secondaryLabel,
        ]))
        for field in fields {
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: field.key + ": ", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel,
            ]))
            line.append(NSAttributedString(string: field.value, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            ]))
            line.addAttribute(.paragraphStyle, value: para(spacingAfter: 1, headIndent: 12), range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 6)]))
        return out
    }

    private static func renderTable(header: [String], rows: [[String]]) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let widths = header.indices.map { i -> Int in
            var w = (header[i] as NSString).size(withAttributes: [.font: font]).width
            for row in rows where i < row.count {
                w = max(w, (row[i] as NSString).size(withAttributes: [.font: font]).width)
            }
            return max(6, Int(w / font.pointSize) + 2)
        }
        let out = NSMutableAttributedString()
        func appendRow(_ cells: [String], bold: Bool) {
            var line = ""
            for (i, cell) in cells.enumerated() where i < widths.count {
                let text = cell.count > widths[i] ? String(cell.prefix(widths[i])) : cell
                line += text.padding(toLength: widths[i], withPad: " ", startingAt: 0) + "  "
            }
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: bold ? UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold) : font,
                .backgroundColor: bold ? UIColor.systemGray6 : UIColor.clear,
            ]))
        }
        appendRow(header, bold: true)
        for row in rows { appendRow(row, bold: false) }
        out.addAttribute(.paragraphStyle, value: para(spacingBefore: 6, spacingAfter: 10), range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: 行内

    private static func renderSpans(_ spans: [Span], baseDir: URL?) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            out.append(renderSpan(span, baseDir: baseDir))
        }
        return out
    }

    private static func renderSpan(_ span: Span, baseDir: URL?) -> NSMutableAttributedString {
        switch span {
        case .text(let s):
            return NSMutableAttributedString(string: s, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        case .code(let s):
            return NSMutableAttributedString(string: s, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .backgroundColor: UIColor.systemGray6,
            ])
        case .bold(let inner):
            let a = renderSpans(inner, baseDir: baseDir)
            a.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 16), range: NSRange(location: 0, length: a.length))
            return a
        case .italic(let inner):
            let a = renderSpans(inner, baseDir: baseDir)
            a.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 16), range: NSRange(location: 0, length: a.length))
            return a
        case .strike(let inner):
            let a = renderSpans(inner, baseDir: baseDir)
            a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: a.length))
            return a
        case .link(let url, let inner):
            let a = renderSpans(inner, baseDir: baseDir)
            a.addAttribute(.link, value: URL(string: url) ?? url, range: NSRange(location: 0, length: a.length))
            return a
        case .autolink(let url):
            let a = NSMutableAttributedString(string: url, attributes: [.font: UIFont.systemFont(ofSize: 16)])
            a.addAttribute(.link, value: URL(string: url) ?? url, range: NSRange(location: 0, length: a.length))
            return a
        case .wiki(let target, let alias):
            let display = alias ?? target
            let comps = URLComponents(string: "\(wikiScheme)://note?target=\(target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target)")
            let a = NSMutableAttributedString(string: display, attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.systemBlue,
                .link: comps?.url as Any,
            ])
            return a
        case .embed(let target):
            // 嵌入以引用块占位 + 内容在渲染端异步补充（深度 1）
            return NSMutableAttributedString(string: "嵌入：\(target)\n", attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel,
                .backgroundColor: UIColor.systemGray6,
            ])
        case .image(let path, let alt):
            return renderImage(path: path, alt: alt, baseDir: baseDir)
        }
    }

    private static func renderImage(path: String, alt: String, baseDir: URL?) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var image: UIImage?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            image = nil // 网络图懒加载在视图层处理；此处先给占位
        } else if let base = baseDir {
            let url = base.appendingPathComponent(path)
            image = UIImage(contentsOfFile: url.path)
        }
        if let image, image.size.width > 0 {
            let maxWidth = max(120, min(620, image.size.width))
            let scale = maxWidth / image.size.width
            let bounded = image.size.height * scale < 900 ? image : nil
            let attachment = NSTextAttachment()
            if let bounded {
                attachment.image = bounded
            } else {
                let size = CGSize(width: maxWidth, height: 900 * (image.size.height / image.size.width))
                attachment.image = image.preparingThumbnail(of: CGSize(width: maxWidth, height: 900))
                _ = size
            }
            attachment.bounds = CGRect(x: 0, y: 0, width: maxWidth, height: attachment.image?.size.height ?? 300)
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: "\n"))
        } else {
            out.append(NSAttributedString(string: "[图片：\(alt.isEmpty ? path : alt)]\n", attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel,
            ]))
        }
        return out
    }

    // MARK: 工具

    private static func para(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0, headIndent: CGFloat = 0, lineSpacing: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.headIndent = headIndent
        p.lineSpacing = lineSpacing
        return p
    }

    private static func newline(_ out: NSMutableAttributedString) {
        out.append(NSAttributedString(string: "\n"))
    }
}
