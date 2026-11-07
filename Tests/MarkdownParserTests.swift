import XCTest
@testable import InkVault

final class MarkdownParserTests: XCTestCase {
    func testHeading() {
        let (fm, blocks) = MarkdownParser.parse("# 大标题\n正文一段")
        XCTAssertNil(fm)
        XCTAssertEqual(blocks.count, 2)
        guard case .heading(let level, _) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(level, 1)
    }

    func testParagraphMergesLines() {
        let (_, blocks) = MarkdownParser.parse("第一行\n第二行")
        guard case .paragraph(let spans) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(spans.first?.plainText, "第一行\n第二行")
    }

    func testCodeFence() {
        let (_, blocks) = MarkdownParser.parse("```swift\nlet a = 1\nlet b = 2\n```")
        guard case .codeFence(let lang, let text) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(text, "let a = 1\nlet b = 2")
    }

    func testBlockquote() {
        let (_, blocks) = MarkdownParser.parse("> 引用内容")
        guard case .blockquote(let children) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(children.count, 1)
    }

    func testUnorderedListWithTasks() {
        let (_, blocks) = MarkdownParser.parse("- 普通项\n- [ ] 未完成\n- [x] 已完成")
        guard case .list(let ordered, _, let items) = blocks[0] else { return XCTFail() }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
        XCTAssertNil(items[0].checked)
        XCTAssertEqual(items[1].checked, false)
        XCTAssertEqual(items[2].checked, true)
    }

    func testOrderedList() {
        let (_, blocks) = MarkdownParser.parse("1. 第一\n2. 第二")
        guard case .list(let ordered, _, let items) = blocks[0] else { return XCTFail() }
        XCTAssertTrue(ordered)
        XCTAssertEqual(items.count, 2)
    }

    func testNestedListChildren() {
        let (_, blocks) = MarkdownParser.parse("- 父项\n  - 子项")
        guard case .list(_, _, let items) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(items[0].children.count, 1)
    }

    func testTable() {
        let (_, blocks) = MarkdownParser.parse("| A | B |\n|---|---|\n| 1 | 2 |")
        guard case .table(let header, let rows) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(header, ["A", "B"])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    func testHR() {
        let (_, blocks) = MarkdownParser.parse("上\n\n---\n\n下")
        XCTAssertTrue(blocks.contains { block in
            if case .hr = block { return true }
            return false
        })
    }

    func testFrontmatter() {
        let text = "---\ntitle: 我的笔记\ntags: a, b\n---\n\n正文"
        let (fm, blocks) = MarkdownParser.parse(text)
        XCTAssertEqual(fm?.count, 2)
        XCTAssertEqual(fm?[0].key, "title")
        XCTAssertEqual(fm?[0].value, "我的笔记")
        XCTAssertEqual(blocks.count, 1)
    }

    // MARK: 行内

    func testBoldItalicStrike() {
        let spans = MarkdownParser.parseSpans("**b** *i* ~~s~~")
        XCTAssertEqual(spans[0], .bold([.text("b")]))
        XCTAssertEqual(spans[1], .text(" "))
        XCTAssertEqual(spans[2], .italic([.text("i")]))
        XCTAssertEqual(spans[4], .strike([.text("s")]))
    }

    func testCodeSpan() {
        let spans = MarkdownParser.parseSpans("前 `code()` 后")
        XCTAssertEqual(spans[1], .code("code()"))
    }

    func testWikilink() {
        let spans = MarkdownParser.parseSpans("见 [[笔记A]] 与 [[笔记B|别名]]")
        XCTAssertEqual(spans[1], .wiki(target: "笔记A", alias: nil))
        XCTAssertEqual(spans[3], .wiki(target: "笔记B", alias: "别名"))
    }

    func testEmbed() {
        let spans = MarkdownParser.parseSpans("![[图片.png]]")
        XCTAssertEqual(spans[0], .embed(target: "图片.png"))
    }

    func testImageAndLink() {
        let spans = MarkdownParser.parseSpans("![猫](imgs/cat.png) 和 [链接](https://x.y)")
        XCTAssertEqual(spans[0], .image(path: "imgs/cat.png", alt: "猫"))
        XCTAssertEqual(spans[2], .link(url: "https://x.y", spans: [.text("链接")]))
    }

    func testAutolink() {
        let spans = MarkdownParser.parseSpans("访问 https://example.com/x 试试")
        XCTAssertEqual(spans[1], .autolink("https://example.com/x"))
    }

    func testUnclosedBoldIsText() {
        let spans = MarkdownParser.parseSpans("a ** b")
        XCTAssertEqual(spans[0].plainText, "a ** b")
    }
}
