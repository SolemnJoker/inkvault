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
        for c in s {
            switch c {
            case "\r": engine.key(.enter)
            case "\u{1B}": engine.key(.escape)
            default: engine.key(.char(c))
            }
        }
    }

    private func assertText(_ expected: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.text, expected, message, file: file, line: line)
    }

    private func assertCursor(row: Int, col: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.cursor.line, row, "cursor line", file: file, line: line)
        XCTAssertEqual(engine.cursor.col, col, "cursor col", file: file, line: line)
    }

    // MARK: 基础移动

    func testTextLoadAndCursor() {
        load("hello\nworld")
        assertCursor(row: 0, col: 0)
        assertText("hello\nworld")
    }

    func testHLMove() {
        load("abcdef")
        type("lll")
        assertCursor(row: 0, col: 3)
        type("hh")
        assertCursor(row: 0, col: 1)
    }

    func testJKMove() {
        load("one\ntwo\nthree")
        type("jj")
        assertCursor(row: 2, col: 0)
        type("k")
        assertCursor(row: 1, col: 0)
    }

    func testDollarAndZero() {
        load("hello")
        type("$")
        assertCursor(row: 0, col: 4)
        type("0")
        assertCursor(row: 0, col: 0)
    }

    func testGGandG() {
        load("l1\nl2\nl3\nl4\nl5")
        type("G")
        assertCursor(row: 4, col: 1)
        type("gg")
        assertCursor(row: 0, col: 0)
        type("3G")
        assertCursor(row: 2, col: 0)
    }

    func testWordForwardBackward() {
        load("foo bar_baz qux")
        type("w")
        assertCursor(row: 0, col: 4)
        type("w")
        assertCursor(row: 0, col: 12)
        type("b")
        assertCursor(row: 0, col: 4)
        type("b")
        assertCursor(row: 0, col: 0)
    }

    func testWordEnd() {
        load("foo bar")
        type("e")
        assertCursor(row: 0, col: 2)
        type("e")
        assertCursor(row: 0, col: 6)
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
        // 光标在 new 行（line 1），O 在其上方开行
        type("O")
        engine.insertText("top")
        engine.key(.escape)
        assertText("abX\ntop\nnew\ncd")
    }

    func testInsertBackspaceJoinsLines() {
        load("ab\ncd")
        type("ji")
        engine.insertBackspace() // 行首退格：并入上一行
        engine.key(.escape)
        assertText("abcd")
        assertCursor(row: 0, col: 2)
    }

    func testInsertBackspaceDeletesBeforeCursor() {
        load("ab\ncd")
        type("jli")
        engine.insertBackspace() // 光标在 d 前：删 c
        engine.key(.escape)
        assertText("ab\nd")
    }

    // MARK: operator

    func testDDDeletesLine() {
        load("l1\nl2\nl3")
        type("dd")
        assertText("l2\nl3")
        assertCursor(row: 0, col: 0)
    }

    func test3DDDeletesThree() {
        load("l1\nl2\nl3\nl4")
        engine.setText("l1\nl2\nl3\nl4", cursorAtEnd: false)
        type("2j")
        assertCursor(row: 2, col: 0)
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
        assertCursor(row: 0, col: 0)
        type("n")
        assertCursor(row: 0, col: 8)
        type("n")
        assertCursor(row: 0, col: 0) // 循环
    }

    func testSearchBackward() {
        load("alpha beta alpha")
        engine.setText("alpha beta alpha", cursorAtEnd: true)
        type("?beta\r")
        assertCursor(row: 0, col: 6)
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
