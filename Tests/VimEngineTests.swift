import XCTest
@testable import InkVault

final class VimEngineTests: XCTestCase {
    private var engine = VimEngine()

    override func setUp() {
        super.setUp()
        engine = VimEngine()
    }

    private func load(_ text: String) {
        engine.setText(text, cursorAtEnd: false)
    }

    private func type(_ s: String) {
        for c in s { engine.key(.char(c)) }
    }

    private func assertText(_ expected: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.text, expected, message, file: file, line: line)
    }

    private func assertCursor(line: Int, col: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.cursor.line, line, "cursor line", file: file, line: line)
        XCTAssertEqual(engine.cursor.col, col, "cursor col", file: file, line: line)
    }

    // MARK: 基础移动

    func testTextLoadAndCursor() {
        load("hello\nworld")
        assertCursor(line: 0, col: 0)
        assertText("hello\nworld")
    }

    func testHLMove() {
        load("abcdef")
        type("lll")
        assertCursor(line: 0, col: 3)
        type("hh")
        assertCursor(line: 0, col: 1)
    }

    func testJKMove() {
        load("one\ntwo\nthree")
        type("jj")
        assertCursor(line: 2, col: 0)
        type("k")
        assertCursor(line: 1, col: 0)
    }

    func testDollarAndZero() {
        load("hello")
        type("$")
        assertCursor(line: 0, col: 4)
        type("0")
        assertCursor(line: 0, col: 0)
    }

    func testGGandG() {
        load("l1\nl2\nl3\nl4\nl5")
        type("G")
        assertCursor(line: 4, col: 1)
        type("gg")
        assertCursor(line: 0, col: 0)
        type("3G")
        assertCursor(line: 2, col: 0)
    }

    func testWordForwardBackward() {
        load("foo bar_baz qux")
        type("w")
        assertCursor(line: 0, col: 4)
        type("w")
        assertCursor(line: 0, col: 12)
        type("b")
        assertCursor(line: 0, col: 4)
        type("b")
        assertCursor(line: 0, col: 0)
    }

    func testWordEnd() {
        load("foo bar")
        type("e")
        assertCursor(line: 0, col: 2)
        type("e")
        assertCursor(line: 0, col: 6)
    }

    // MARK: 插入模式

    func testInsertModeTyping() {
        load("hello")
        type("i")
        XCTAssertEqual(engine.mode, .insert)
        engine.insertText("XY")
        engine.key(.escape)
        XCTAssertEqual(engine.mode, .normal)
        assertText("XYhello")
    }

    func testAppendAndOpenLine() {
        load("ab\ncd")
        type("A")
        XCTAssertEqual(engine.mode, .insert)
        engine.insertText("X")
        engine.key(.escape)
        assertText("abX\ncd")
        type("o")
        engine.insertText("new")
        engine.key(.escape)
        assertText("abX\nnew\ncd")
        type("O")
        engine.insertText("top")
        engine.key(.escape)
        assertText("top\nabX\nnew\ncd")
    }

    func testInsertBackspaceJoinsLines() {
        load("ab\ncd")
        type("jli")
        engine.insertBackspace()
        engine.key(.escape)
        assertText("abcd")
    }

    // MARK: operator

    func testDDDeletesLine() {
        load("l1\nl2\nl3")
        type("dd")
        assertText("l2\nl3")
        assertCursor(line: 0, col: 0)
    }

    func test3DDDeletesThree() {
        load("l1\nl2\nl3\nl4")
        engine.setText("l1\nl2\nl3\nl4", cursorAtEnd: false)
        type("2j")
        assertCursor(line: 2, col: 0)
        type("3dd")
        assertText("l1\nl4")
    }

    func testDWDeletesWord() {
        load("foo bar qux")
        type("dw")
        assertText("bar qux")
    }

    func testDollarDelete() {
        load("hello world")
        type("ld$")
        assertText("h")
    }

    func testXDeletesChar() {
        load("abc")
        type("x")
        assertText("bc")
        type("2x")
        assertText("")
    }

    func testCChangeToEnd() {
        load("hello world")
        type("C")
        XCTAssertEqual(engine.mode, .insert)
        engine.insertText("!")
        engine.key(.escape)
        assertText("!")
    }

    func testYankLineAndPaste() {
        load("l1\nl2")
        type("yyjp")
        assertText("l1\nl2\nl2")
    }

    func testDDThenPUndoesDeletion() {
        load("l1\nl2")
        type("ddp")
        assertText("l2\nl1")
    }

    func testVisualDeleteCharwise() {
        load("hello world")
        type("vllld")
        assertText("o world")
    }

    func testVisualLineYankPaste() {
        load("a\nb\nc")
        type("jVyjp")
        assertText("a\nb\nb\nc")
    }

    // MARK: 撤销重做

    func testUndoRedo() {
        load("abc")
        type("x")
        assertText("bc")
        type("u")
        assertText("abc")
        engine.key(.ctrlR)
        assertText("bc")
    }

    func testUndoAfterDD() {
        load("l1\nl2")
        type("ddu")
        assertText("l1\nl2")
    }

    // MARK: 搜索

    func testSearchForwardAndN() {
        load("one two one two")
        type("/one\r")
        assertCursor(line: 0, col: 0)
        type("n")
        assertCursor(line: 0, col: 8)
        type("n")
        assertCursor(line: 0, col: 0) // 循环
    }

    func testSearchBackward() {
        load("alpha beta alpha")
        engine.setText("alpha beta alpha", cursorAtEnd: true)
        type("?beta\r")
        assertCursor(line: 0, col: 6)
    }

    // MARK: 替换

    func testSubstituteCurrentLine() {
        load("cat dog cat")
        type(":s/cat/dog\r")
        assertText("dog dog cat")
    }

    func testGlobalSubstitute() {
        load("aXa\naXa")
        engine.setText("aXa\naXa", cursorAtEnd: false)
        type(":%s/X/Y/g\r")
        assertText("aYa\naYa")
    }

    // MARK: 边界

    func testCursorClampOnEmptyBuffer() {
        load("")
        type("jkl$x")
        assertText("")
    }

    func testUnsupportedCommandMessage() {
        load("abc")
        type("Z")
        XCTAssertFalse(engine.message.isEmpty)
    }

    func testCJKEdit() {
        load("你好，世界")
        type("x")
        assertText("好，世界")
        type("A")
        engine.insertText("！")
        engine.key(.escape)
        assertText("好，世界！")
    }
}
