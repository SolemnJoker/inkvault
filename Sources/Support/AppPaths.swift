import Foundation

/// 沙盒内固定路径集中管理。同步凭证/内核状态一律在沙盒（D-07）。
enum AppPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    /// 同步内核 home（config.xml/证书/数据库）。
    static var syncHome: URL {
        applicationSupport.appendingPathComponent("sync-home", isDirectory: true)
    }

    /// 操作日志（D-09）：append-only，仅存沙盒，不写入 vault。
    static var operationLog: URL {
        applicationSupport.appendingPathComponent("operations.jsonl")
    }

    /// vault 注册表。
    static var vaultRegistry: URL {
        applicationSupport.appendingPathComponent("vaults.json")
    }

    /// 同步配置（中继/设备 ID 等，非机密）。
    static var syncConfig: URL {
        applicationSupport.appendingPathComponent("sync-config.json")
    }
}
