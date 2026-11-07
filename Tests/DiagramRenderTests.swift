import XCTest
@testable import InkVault

final class DiagramRenderTests: XCTestCase {
    // MARK: 解析

    func testInlineMathParsing() {
        let spans = MarkdownParser.parseSpans("质能方程 $E=mc^2$ 很有名")
        XCTAssertEqual(spans[1], .math(tex: "E=mc^2", display: false))
    }

    func testDisplayMathParsing() {
        let spans = MarkdownParser.parseSpans("积分: $$\\int_0^1 x dx$$ 结束")
        XCTAssertEqual(spans[1], .math(tex: "\\int_0^1 x dx", display: true))
    }

    func testUnclosedDollarStaysText() {
        let spans = MarkdownParser.parseSpans("价格 $5 和 $10 都行")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].plainText, "价格 $5 和 $10 都行")
    }

    func testMermaidFenceDetected() {
        let (_, blocks) = MarkdownParser.parse("```mermaid\ngraph TD;A-->B;\n```")
        guard case .codeFence(let lang, let text) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(lang, "mermaid")
        XCTAssertEqual(text, "graph TD;A-->B;")
    }

    // MARK: 引擎冒烟（模拟器上跑真实 WKWebView 离屏渲染）

    func testKaTeXRenderSmoke() throws {
        guard let html = Bundle.main.url(forResource: "render", withExtension: "html", subdirectory: "renderer"),
              FileManager.default.fileExists(atPath: html.deletingLastPathComponent().appendingPathComponent("katex.min.js").path)
        else { throw XCTSkip("渲染资源未打包") }

        let exp = expectation(description: "katex render")
        var result: DiagramResult?
        DiagramRenderEngine.shared.render(kind: .math, code: "E=mc^2", itemID: "t1") { r in
            result = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 40)
        let r = try XCTUnwrap(result)
        XCTAssertNil(r.error, "KaTeX 渲染报错: \(r.error ?? "")")
        XCTAssertGreaterThan(r.size.width, 4)
        XCTAssertGreaterThan(r.size.height, 4)
        DiagramRenderEngine.shared.tearDown()
    }

    func testMermaidRenderSmoke() throws {
        guard Bundle.main.url(forResource: "render", withExtension: "html", subdirectory: "renderer") != nil else {
            throw XCTSkip("渲染资源未打包")
        }
        let exp = expectation(description: "mermaid render")
        var result: DiagramResult?
        DiagramRenderEngine.shared.render(kind: .mermaid, code: "graph TD; A[开始] --> B[结束];", itemID: "t2") { r in
            result = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 40)
        let r = try XCTUnwrap(result)
        XCTAssertNil(r.error, "Mermaid 渲染报错: \(r.error ?? "")")
        XCTAssertGreaterThan(r.size.width, 10)
        XCTAssertGreaterThan(r.size.height, 10)
        DiagramRenderEngine.shared.tearDown()
    }

    func testEngineTearDownDestroysWebView() {
        DiagramRenderEngine.shared.tearDown()
        XCTAssertFalse(DiagramRenderEngine.shared.isEngineAlive)
    }
}
