import Foundation

struct SearchResult: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var name: String
    var matchType: MatchType
    var snippet: String?

    enum MatchType: Equatable {
        case filename
        case content
    }
}

/// 按需检索（US-11、NFR-03）：无常驻索引，搜索结束即停；跳过隐藏目录。
final class SearchService {
    private let session: VaultSession

    init(session: VaultSession) {
        self.session = session
    }

    /// 搜索文件名与内容；async 以便在后台任务中取消。
    func search(_ query: String, limit: Int = 100) async -> [SearchResult] {
        guard let root = session.rootURL, !query.isEmpty else { return [] }
        let q = query.lowercased()
        var results: [SearchResult] = []
        var files = 0

        func walk(_ dir: URL) async {
            guard results.count < limit, files < 5000 else { return }
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: FileManager.DirectoryEnumerationOptions()) else { return }
            for item in items {
                if results.count >= limit { return }
                if VaultInternal.isHiddenName(item.lastPathComponent) { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    await walk(item)
                    continue
                }
                files += 1
                let relative = item.path.hasPrefix(root.path + "/") ? String(item.path.dropFirst(root.path.count + 1)) : item.lastPathComponent
                if item.lastPathComponent.lowercased().contains(q) {
                    results.append(SearchResult(path: relative, name: item.lastPathComponent, matchType: .filename, snippet: nil))
                    continue
                }
                // 内容搜索：仅文本类文件，限制单文件大小
                if item.pathExtension.lowercased() == "md" || item.pathExtension.isEmpty {
                    let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    guard size < 4_000_000 else { continue }
                    if let text = try? String(contentsOf: item, encoding: .utf8) {
                        if let line = text.split(separator: "\n").first(where: { $0.lowercased().contains(q) }) {
                            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                            let snippet = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
                            results.append(SearchResult(path: relative, name: item.lastPathComponent, matchType: .content, snippet: snippet))
                        }
                    }
                }
            }
        }

        await walk(root)
        return results
    }
}
