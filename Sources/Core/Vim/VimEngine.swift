import Foundation

/// Vim 引擎（纯逻辑，不接触 UIKit）。
/// 本期范围（需求方确认）：normal/insert/visual、核心 motions + operators + 计数、
/// 搜索（/ ? n/N）与替换（:s、:%s 字面量）。不含宏、命名寄存器、marks。
final class VimEngine {
    enum Mode: Equatable {
        case normal
        case insert
        case visualChar
        case visualLine
        case exCommand
    }

    enum Operator: String {
        case delete = "d"
        case change = "c"
        case yank = "y"
    }

    enum Key: Equatable {
        case char(Character)
        case enter
        case escape
        case backspace
        case ctrlR
    }

    struct Position: Equatable {
        var line: Int
        var col: Int // 图素（grapheme cluster）下标
    }

    private(set) var lines: [[Character]] = [[""]]
    private(set) var cursor = Position(line: 0, col: 0)
    private(set) var mode: Mode = .normal
    private(set) var pendingCount: Int?
    private(set) var pendingOperator: Operator?
    private(set) var visualAnchor: Position?
    private(set) var pendingEx = ""
    /// 状态栏消息（-- INSERT --、搜索结果等）。
    private(set) var message = ""

    private var register = ""            // 未命名寄存器
    private var registerIsLinewise = false
    private var undoStack: [(lines: [[Character]], cursor: Position)] = []
    private var redoStack: [(lines: [[Character]], cursor: Position)] = []
    private(set) var lastSearch: (pattern: String, backward: Bool)?
    private var lastSearchHit: Position?

    // MARK: - 文本交互

    var text: String {
        get { lines.map(String.init).joined(separator: "\n") }
        set { setText(newValue, cursorAtEnd: false) }
    }

    func setText(_ string: String, cursorAtEnd: Bool) {
        let ls = string.components(separatedBy: "\n").map(Array.init)
        lines = ls.isEmpty ? [[""]] : ls
        if cursorAtEnd {
            let last = lines.count - 1
            cursor = Position(line: last, col: max(0, lines[last].count - 1))
        } else {
            cursor = Position(line: 0, col: 0)
        }
        mode = .normal
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// insert 模式的编辑由宿主（UITextView）直接落到 buffer，用此接口同步。
    func syncFromText(_ string: String, cursorLine: Int, cursorCol: Int) {
        let ls = string.components(separatedBy: "\n").map(Array.init)
        lines = ls.isEmpty ? [[""]] : ls
        cursor.line = min(cursorLine, lines.count - 1)
        cursor.col = min(cursorCol, lines[cursor.line].count)
    }

    // MARK: - 按键入口

    func key(_ key: Key) {
        if mode == .exCommand {
            handleExKey(key)
            return
        }
        switch (mode, key) {
        case (_, .escape):
            cancelPending()
            mode = .normal
            message = ""
            clampCursor()
        case (.insert, _):
            // insert 模式按键由宿主直接输入；引擎仅响应 esc（上方分支）。
            break
        case (.normal, .ctrlR):
            redo()
        case (.visualChar, .ctrlR), (.visualLine, .ctrlR):
            break
        case (.normal, let k):
            handleNormal(k)
        case (.visualChar, let k), (.visualLine, let k):
            handleVisual(k)
        }
    }

    /// 供 UITextView 在 insert 模式把一次字符输入后同步回引擎。
    func insertText(_ string: String) {
        guard mode == .insert else { return }
        snapshotUndo()
        let chunks = string.components(separatedBy: "\n").map(Array.init)
        let line = lines[cursor.line]
        let head = Array(line.prefix(cursor.col))
        let tail = Array(line.suffix(line.count - cursor.col))
        if chunks.count == 1 {
            lines[cursor.line] = head + chunks[0] + tail
            cursor.col += chunks[0].count
        } else {
            lines[cursor.line] = head + chunks[0]
            var inserted = Array(chunks.dropFirst())
            inserted[inserted.count - 1] += tail
            lines.insert(contentsOf: inserted, at: cursor.line + 1)
            cursor.line += inserted.count
            cursor.col = chunks[chunks.count - 1].count
        }
        clampCursor()
    }

    func insertNewline() {
        insertText("\n")
    }

    func insertBackspace() {
        guard mode == .insert else { return }
        snapshotUndo()
        if cursor.col > 0 {
            let line = lines[cursor.line]
            lines[cursor.line] = Array(line.prefix(cursor.col - 1)) + Array(line.suffix(line.count - cursor.col))
            cursor.col -= 1
        } else if cursor.line > 0 {
            let prev = lines[cursor.line - 1]
            let cur = lines[cursor.line]
            cursor.col = prev.count
            lines[cursor.line - 1] = prev + cur
            lines.remove(at: cursor.line)
            cursor.line -= 1
        }
        clampCursor()
    }

    // MARK: - normal 模式

    private func handleNormal(_ key: Key) {
        guard case .char(let c) = key else {
            if case .enter = key { moveToLineStart(); cursor.line = min(cursor.line + 1, lines.count - 1); clampCursor() }
            return
        }
        // 计数前缀
        if c.isNumber, c != "0" || pendingCount != nil {
            let n = Int(String(c)) ?? 0
            pendingCount = (pendingCount ?? 0) * 10 + n
            return
        }
        // operator 等待 motion
        if let op = pendingOperator {
            if c == op.rawValue.first { // dd / cc / yy 行操作
                finishOperatorLine(op)
                return
            }
            runOperatorMotion(op, motionChar: c)
            return
        }
        switch c {
        case "h": move(times: count1, by: { $0.col -= 1 }); consumeCount()
        case "l": move(times: count1, by: { $0.col += 1 }); consumeCount()
        case "j": move(times: count1, by: { $0.line = min($0.line + 1, lines.count - 1); $0.col = min($0.col, max(0, lineCount($0.line) - 1)) }); consumeCount()
        case "k": move(times: count1, by: { $0.line = max($0.line - 1, 0); $0.col = min($0.col, max(0, lineCount($0.line) - 1)) }); consumeCount()
        case "w": move(times: count1, by: wordForward); consumeCount()
        case "b": move(times: count1, by: wordBackward); consumeCount()
        case "e": move(times: count1, by: wordEnd); consumeCount()
        case "0": cursor.col = 0
        case "^": moveToFirstNonBlank()
        case "$": cursor.col = max(0, lineCount(cursor.line) - 1)
        case "g":
            // gg 简化：下一个 g 触发行首；这里直接当 gg 处理
            if let n = pendingCount, n >= 1 { cursor.line = min(n - 1, lines.count - 1) } else { cursor.line = 0 }
            moveToFirstNonBlank(); consumeCount()
        case "G":
            if let n = pendingCount, n >= 1 { cursor.line = min(n - 1, lines.count - 1) } else { cursor.line = lines.count - 1 }
            moveToFirstNonBlank(); consumeCount()
        case "d": pendingOperator = .delete
        case "c": pendingOperator = .change
        case "y": pendingOperator = .yank
        case "x": finishOperatorCharwise(op: .delete, lines: cursor.line..<cursor.line + 1, startCol: cursor.col, endCol: min(cursor.col + count1, lineCount(cursor.line)), linewise: false)
        case "D": finishOperatorCharwise(op: .delete, lines: cursor.line..<cursor.line + 1, startCol: cursor.col, endCol: lineCount(cursor.line), linewise: false)
        case "C": finishOperatorCharwise(op: .change, lines: cursor.line..<cursor.line + 1, startCol: cursor.col, endCol: lineCount(cursor.line), linewise: false)
        case "p": paste(after: true)
        case "P": paste(after: false)
        case "i": mode = .insert
        case "a": if lineCount(cursor.line) > 0 { cursor.col = min(cursor.col + 1, lineCount(cursor.line)) }; mode = .insert
        case "I": moveToFirstNonBlank(); mode = .insert
        case "A": cursor.col = lineCount(cursor.line); mode = .insert
        case "o": openLine(below: true)
        case "O": openLine(below: false)
        case "u": undo()
        case "v": mode = .visualChar; visualAnchor = cursor
        case "V": mode = .visualLine; visualAnchor = cursor
        case "/": startSearch(backward: false)
        case "?": startSearch(backward: true)
        case "n": jumpSearch(forward: lastSearch.map { !$0.backward } ?? true)
        case "N": jumpSearch(forward: lastSearch.map { $0.backward } ?? false)
        case ":": mode = .exCommand; pendingEx = ""
        default:
            message = "未支持命令：\(c)"
        }
        clampCursor()
    }

    // MARK: - visual 模式

    private func handleVisual(_ key: Key) {
        guard case .char(let c) = key else { return }
        if c.isNumber, c != "0" || pendingCount != nil {
            let n = Int(String(c)) ?? 0
            pendingCount = (pendingCount ?? 0) * 10 + n
            return
        }
        switch c {
        case "v": mode = .visualChar; visualAnchor = cursor
        case "V": mode = .visualLine; visualAnchor = cursor
        case "j": move(times: count1, by: { $0.line = min($0.line + 1, lines.count - 1); $0.col = min($0.col, max(0, lineCount($0.line) - 1)) }); consumeCount()
        case "k": move(times: count1, by: { $0.line = max($0.line - 1, 0); $0.col = min($0.col, max(0, lineCount($0.line) - 1)) }); consumeCount()
        case "h": move(times: count1, by: { $0.col -= 1 }); consumeCount()
        case "l": move(times: count1, by: { $0.col += 1 }); consumeCount()
        case "w": move(times: count1, by: wordForward); consumeCount()
        case "b": move(times: count1, by: wordBackward); consumeCount()
        case "0": cursor.col = 0
        case "$": cursor.col = max(0, lineCount(cursor.line) - 1)
        case "d", "x": applyVisual(op: .delete)
        case "c": applyVisual(op: .change)
        case "y": applyVisual(op: .yank)
        case "p": applyVisualPaste()
        default:
            message = "未支持命令：\(c)"
        }
        clampCursor()
    }

    /// 当前可视选区（起点在前）。char 模式含两端；line 模式为整行集合。
    func visualRange() -> (start: Position, end: Position)? {
        guard let anchor = visualAnchor, mode == .visualChar || mode == .visualLine else { return nil }
        let (a, b) = ordered(anchor, cursor)
        return (a, b)
    }

    private func applyVisual(_ op: Operator) {
        guard mode == .visualChar || mode == .visualLine else { return }
        if mode == .visualLine {
            finishOperatorLine(op, lineRange: visualRange().map { r in
                r.start.line...min(r.end.line, lines.count - 1)
            })
        } else {
            guard let r = visualRange() else { return }
            finishOperatorCharwise(op: op, lines: r.start.line...r.end.line, startCol: r.start.col, endCol: min(r.end.col + 1, lineCount(r.end.line)), linewise: false)
        }
        mode = .normal
        visualAnchor = nil
    }

    private func applyVisualPaste() {
        guard let r = visualRange() else { return }
        snapshotUndo()
        let selected = extractRange(lines: r.start.line...r.end.line, startCol: r.start.col, endCol: min(r.end.col + 1, lineCount(r.end.line)), linewise: mode == .visualLine)
        deleteRange(lines: r.start.line...r.end.line, startCol: r.start.col, endCol: min(r.end.col + 1, lineCount(r.end.line)), linewise: mode == .visualLine)
        register = selected
        registerIsLinewise = (mode == .visualLine)
        paste(after: false)
        mode = .normal
        visualAnchor = nil
    }

    // MARK: - operator 执行

    private func finishOperatorLine(_ op: Operator, lineRange: ClosedRange<Int>? = nil) {
        let n = pendingCount ?? 1
        let range: ClosedRange<Int>
        if let given = lineRange {
            range = given
        } else {
            let end = min(cursor.line + n - 1, lines.count - 1)
            range = min(cursor.line, end)...max(cursor.line, end)
        }
        finishOperatorLineOnly(op, range: range)
    }

    private func finishOperatorLineOnly(_ op: Operator, range: ClosedRange<Int>) {
        snapshotUndo()
        switch op {
        case .yank:
            register = range.map { String(lines[$0]) }.joined(separator: "\n")
            registerIsLinewise = true
            cursor = Position(line: range.lowerBound, col: 0)
        case .delete:
            register = range.map { String(lines[$0]) }.joined(separator: "\n")
            registerIsLinewise = true
            deleteRange(lines: range, startCol: 0, endCol: 0, linewise: true)
            cursor = Position(line: min(range.lowerBound, lines.count - 1), col: 0)
        case .change:
            register = range.map { String(lines[$0]) }.joined(separator: "\n")
            registerIsLinewise = true
            deleteRange(lines: range, startCol: 0, endCol: 0, linewise: true)
            cursor = Position(line: min(range.lowerBound, lines.count - 1), col: 0)
            mode = .insert
        }
        pendingOperator = nil
        consumeCount()
        clampCursor()
    }

    private func runOperatorMotion(_ op: Operator, motionChar: Character) {
        let n = pendingCount ?? 1
        var target = cursor
        for _ in 0..<n {
            switch motionChar {
            case "w": wordForward(&target)
            case "b": wordBackward(&target)
            case "e": wordEnd(&target)
            case "0": target.col = 0
            case "^": target.col = firstNonBlank(target.line)
            case "$": target.col = max(0, lineCount(target.line) - 1)
            default:
                pendingOperator = nil; consumeCount()
                message = "未支持 operator motion：\(op.rawValue)\(motionChar)"
                return
            }
        }
        let (start, end) = ordered(cursor, target)
        // w/e 动作在行尾语义：end 落到下一行首时收回上一行末尾
        finishOperatorCharwise(op: op, lines: start.line...end.line, startCol: start.col, endCol: min(end.col + (motionChar == "b" || motionChar == "0" || motionChar == "^" ? 0 : 1), lineCount(end.line)), linewise: false)
    }

    private func finishOperatorCharwise(op: Operator, lines lineRange: ClosedRange<Int>, startCol: Int, endCol: Int, linewise: Bool) {
        snapshotUndo()
        let removed = extractRange(lines: lineRange, startCol: startCol, endCol: endCol, linewise: linewise)
        register = removed
        registerIsLinewise = linewise
        switch op {
        case .yank:
            break
        case .delete:
            deleteRange(lines: lineRange, startCol: startCol, endCol: endCol, linewise: linewise)
            cursor = Position(line: min(startCol == 0 ? lineRange.lowerBound : lineRange.lowerBound, lines.count - 1), col: min(startCol, max(0, lineCount(min(lineRange.lowerBound, lines.count - 1)) - 1)))
        case .change:
            deleteRange(lines: lineRange, startCol: startCol, endCol: endCol, linewise: linewise)
            cursor = Position(line: lineRange.lowerBound, col: startCol)
            mode = .insert
        }
        pendingOperator = nil
        consumeCount()
        clampCursor()
    }

    private func deleteRange(lines lineRange: ClosedRange<Int>, startCol: Int, endCol: Int, linewise: Bool) {
        if linewise {
            guard lines.count > lineRange.count else {
                // 整个 buffer：清空内容
                lines = [[""]]
                cursor = Position(line: 0, col: 0)
                return
            }
            lines.removeSubrange(lineRange)
            if lines.isEmpty { lines = [[""]] }
            return
        }
        if lineRange.count == 1 {
            let line = lines[lineRange.lowerBound]
            lines[lineRange.lowerBound] = Array(line.prefix(startCol)) + Array(line.suffix(max(0, line.count - endCol)))
            return
        }
        let first = lines[lineRange.lowerBound]
        let last = lines[lineRange.upperBound]
        let merged = Array(first.prefix(startCol)) + Array(last.suffix(max(0, last.count - endCol)))
        lines.removeSubrange(lineRange)
        lines.insert(merged, at: lineRange.lowerBound)
    }

    private func extractRange(lines lineRange: ClosedRange<Int>, startCol: Int, endCol: Int, linewise: Bool) -> String {
        if linewise {
            return lineRange.map { String(self.lines[$0]) }.joined(separator: "\n")
        }
        if lineRange.count == 1 {
            let line = self.lines[lineRange.lowerBound]
            return String(line[min(startCol, line.count)..<min(endCol, line.count)])
        }
        let first = String(self.lines[lineRange.lowerBound][min(startCol, self.lines[lineRange.lowerBound].count)...])
        let last = String(self.lines[lineRange.upperBound][..<min(endCol, self.lines[lineRange.upperBound].count)])
        let middle = (lineRange.lowerBound + 1)..<lineRange.upperBound
        let mid = middle.map { String(self.lines[$0]) }
        return ([first] + mid + [last]).joined(separator: "\n")
    }

    private func paste(after: Bool) {
        snapshotUndo()
        if registerIsLinewise {
            let pasted = register.components(separatedBy: "\n").map(Array.init)
            let at = after ? cursor.line + 1 : cursor.line
            lines.insert(contentsOf: pasted, at: at)
            cursor = Position(line: at, col: 0)
        } else {
            let chars = Array(register)
            guard !chars.isEmpty else { return }
            let line = lines[cursor.line]
            let at = after ? min(cursor.col + 1, line.count) : cursor.col
            lines[cursor.line] = Array(line.prefix(at)) + chars + Array(line.suffix(line.count - at))
            cursor.col = at
        }
        clampCursor()
    }

    private func openLine(below: Bool) {
        snapshotUndo()
        let at = below ? cursor.line + 1 : cursor.line
        lines.insert([], at: at)
        cursor = Position(line: at, col: 0)
        mode = .insert
    }

    // MARK: - 撤销重做

    private func snapshotUndo() {
        undoStack.append((lines, cursor))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { message = "已在最早变更"; return }
        redoStack.append((lines, cursor))
        lines = prev.lines
        cursor = prev.cursor
    }

    private func redo() {
        guard let next = redoStack.popLast() else { message = "已在最新变更"; return }
        undoStack.append((lines, cursor))
        lines = next.lines
        cursor = next.cursor
    }

    // MARK: - 搜索与替换

    private func startSearch(backward: Bool) {
        mode = .exCommand
        pendingEx = backward ? "?" : "/"
    }

    private func jumpSearch(forward: Bool) {
        guard let search = lastSearch else { message = "无历史搜索"; return }
        let pattern = Array(search.pattern)
        guard !pattern.isEmpty else { return }
        let stepForward = forward != search.backward
        var (line, col) = (cursor.line, cursor.col)
        // 起点错位：前进从当前匹配之后开始，后退从之前开始（n 不得停在原位）
        func advance(_ forwardStep: Bool) {
            if forwardStep {
                col += 1
                if col > max(0, lineCount(line) - pattern.count) {
                    line += 1
                    if line >= lines.count { line = 0 }
                    col = 0
                }
            } else {
                col -= 1
                if col < 0 {
                    line -= 1
                    if line < 0 { line = lines.count - 1 }
                    col = max(0, lineCount(line) - pattern.count)
                }
            }
        }
        advance(stepForward)
        let total = lines.reduce(0) { $0 + $1.count } + 2
        for _ in 0..<max(total, 4) {
            if stepForward {
                if col + pattern.count <= lineCount(line), match(atLine: line, col: col, pattern: pattern) {
                    cursor = Position(line: line, col: col)
                    lastSearchHit = cursor
                    return
                }
            } else {
                if col + pattern.count <= lineCount(line), match(atLine: line, col: col, pattern: pattern) {
                    cursor = Position(line: line, col: col)
                    lastSearchHit = cursor
                    return
                }
            }
            advance(stepForward)
        }
        message = "未找到：\(search.pattern)"
    }

    private func match(atLine line: Int, col: Int, pattern: [Character]) -> Bool {
        let text = lines[line]
        guard col + pattern.count <= text.count else { return false }
        for (i, p) in pattern.enumerated() {
            if text[col + i].lowercased() != p.lowercased() { return false }
        }
        return true
    }

    private func handleExKey(_ key: Key) {
        switch key {
        case .escape:
            mode = .normal
            pendingEx = ""
        case .enter:
            runExCommand(pendingEx)
            if mode != .insert { mode = .normal }
            pendingEx = ""
        case .backspace:
            if pendingEx.count > 1 { pendingEx.removeLast() } else { mode = .normal; pendingEx = "" }
        case .char(let c):
            pendingEx.append(c)
        case .ctrlR:
            break
        }
    }

    private func runExCommand(_ raw: String) {
        let cmd = raw
        if cmd.hasPrefix("/") || cmd.hasPrefix("?") {
            let backward = cmd.hasPrefix("?")
            let pattern = String(cmd.dropFirst())
            guard !pattern.isEmpty else { return }
            lastSearch = (pattern, backward)
            jumpSearch(forward: !backward)
            return
        }
        // :s/from/to/[g] 与 :%s/from/to/[g]
        var body = cmd
        var global = false
        if body.hasPrefix("%s/") || body.hasPrefix("%s＼") {
            global = true
            body = String(body.dropFirst(2))
        } else if !body.hasPrefix("s/") {
            message = "不支持的命令：\(cmd)"
            return
        }
        let parts = body.split(separator: "/", omittingEmptySubsequence: false).map(String.init)
        guard parts.count >= 3 else { message = "替换格式：:s/旧/新/[g]"; return }
        let from = parts[1]
        let to = parts[2]
        let all = parts.count > 3 && parts[3].contains("g")
        if from.isEmpty { message = "查找串不能为空"; return }
        snapshotUndo()
        let targetLines = global ? 0..<lines.count : cursor.line..<cursor.line + 1
        var replaced = 0
        for li in targetLines {
            var line = String(lines[li])
            if line.lowercased().contains(from.lowercased()) {
                var result = ""
                var searchStart = line.startIndex
                let lowerLine = line.lowercased()
                let lowerFrom = from.lowercased()
                while let range = lowerLine.range(of: lowerFrom, range: searchStart..<line.endIndex) {
                    result += line[searchStart..<range.lowerBound] + to
                    searchStart = range.upperBound
                    replaced += 1
                    if !all { break }
                }
                result += line[searchStart...]
                lines[li] = Array(result)
            }
        }
        message = replaced > 0 ? "替换 \(replaced) 处" : "未找到：\(from)"
    }

    var exPrompt: String { pendingEx }

    // MARK: - 移动原语

    private func move(times: Int, by fn: (inout Position) -> Void) {
        for _ in 0..<max(1, times) {
            var p = cursor
            fn(&p)
            cursor = p
        }
    }

    private func wordForward(_ p: inout Position) {
        var (l, c) = (p.line, p.col)
        let lineChars = lines[l]
        // 跳过当前词
        var i = c
        if i < lineChars.count, !isSpace(lineChars[i]) {
            let cls = charClass(lineChars[i])
            while i < lineChars.count, charClass(lineChars[i]) == cls { i += 1 }
        }
        // 跳过空白
        while i < lineChars.count, isSpace(lineChars[i]) { i += 1 }
        if i >= lineChars.count {
            // 下一行
            if l + 1 < lines.count { l += 1; c = 0 } else { c = max(0, lineChars.count - 1); p = Position(line: l, col: c); return }
        } else {
            c = i
        }
        p = Position(line: l, col: c)
    }

    private func wordBackward(_ p: inout Position) {
        var (l, c) = (p.line, p.col)
        func prevNonBlank() -> Bool {
            var i = c - 1
            var lineChars = lines[l]
            while true {
                while i >= 0, isSpace(lineChars[i]) { i -= 1 }
                if i >= 0 { c = i; return true }
                if l == 0 { c = 0; return true }
                l -= 1
                lineChars = lines[l]
                i = lineChars.count - 1
            }
        }
        guard prevNonBlank() else { return }
        let lineChars = lines[l]
        if c < lineChars.count {
            let cls = charClass(lineChars[c])
            var i = c
            while i > 0, charClass(lineChars[i - 1]) == cls { i -= 1 }
            c = i
        }
        p = Position(line: l, col: c)
    }

    private func wordEnd(_ p: inout Position) {
        var (l, c) = (p.line, p.col)
        c = min(c + 1, lineCount(l) - 1)
        var lineChars = lines[l]
        while true {
            while c < lineChars.count, isSpace(lineChars[c]) { c += 1 }
            if c >= lineChars.count {
                if l + 1 < lines.count { l += 1; lineChars = lines[l]; c = 0 } else { break }
                continue
            }
            break
        }
        if c < lineChars.count {
            let cls = charClass(lineChars[c])
            var i = c
            while i + 1 < lineChars.count, charClass(lineChars[i + 1]) == cls { i += 1 }
            c = i
        }
        p = Position(line: l, col: c)
    }

    // MARK: - 工具

    private var count1: Int { max(1, pendingCount ?? 1) }

    private func consumeCount() { pendingCount = nil }

    private func cancelPending() {
        pendingOperator = nil
        pendingCount = nil
        visualAnchor = nil
    }

    private func clampCursor() {
        cursor.line = max(0, min(cursor.line, lines.count - 1))
        let maxCol = mode == .insert ? lineCount(cursor.line) : max(0, lineCount(cursor.line) - 1)
        cursor.col = max(0, min(cursor.col, maxCol))
    }

    private func moveToFirstNonBlank() {
        cursor.col = firstNonBlank(cursor.line)
    }

    private func firstNonBlank(_ line: Int) -> Int {
        let chars = lines[line]
        var i = 0
        while i < chars.count, isSpace(chars[i]) { i += 1 }
        return min(i, max(0, chars.count - 1))
    }

    private func lineCount(_ line: Int) -> Int { lines[line].count }

    private func ordered(_ a: Position, _ b: Position) -> (Position, Position) {
        if a.line < b.line || (a.line == b.line && a.col <= b.col) { return (a, b) }
        return (b, a)
    }

    private func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }

    private func charClass(_ c: Character) -> Int {
        if isSpace(c) { return 0 }
        if c.isLetter || c.isNumber || c == "_" { return 1 }
        return 2
    }
}
