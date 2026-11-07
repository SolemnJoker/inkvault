import Foundation

// MARK: - REST 模型（仅取所需字段）

struct FullConfig: Codable {
    var version: Int?
    var devices: [DeviceConfig]
    var folders: [FolderConfig]
    var gui: GUIConfig?
    var options: OptionsConfig?
    var defaults: Defaults?

    struct DeviceConfig: Codable {
        var deviceID: String
        var name: String?
        var addresses: [String]?
        var compression: String?
        var certName: String?
        var introducer: Bool?
        var skipIntroductionRemovals: Bool?
        var introducedBy: String?
        var paused: Bool?
        var allowedNetworks: [String]?
        var autoAcceptFolders: Bool?
        var maxSendKbps: Int?
        var maxRecvKbps: Int?
    }

    struct FolderConfig: Codable {
        var id: String
        var label: String?
        var filesystemType: String?
        var path: String
        var type: String?
        var devices: [SharedDevice]?
        var rescanIntervalS: Int?
        var fsWatcherEnabled: Bool?
        var ignorePerms: Bool?
        var autoNormalize: Bool?
        var minDiskFree: UnitValue?
        var versioning: Versioning?
        var paused: Bool?

        struct SharedDevice: Codable {
            var deviceID: String
            var introducedBy: String?
            var encryptionPassword: String?
        }

        struct UnitValue: Codable {
            var value: Double?
            var unit: String?
        }

        struct Versioning: Codable {
            var type: String?
            var params: [String: String]?
        }
    }

    struct GUIConfig: Codable {
        var enabled: Bool?
        var address: String?
        var apiKey: String?
        var useTLS: Bool?
    }

    struct OptionsConfig: Codable {
        var listenAddresses: [String]?
        var globalAnnounceEnabled: Bool?
        var localAnnounceEnabled: Bool?
        var relaysEnabled: Bool?
        var natEnabled: Bool?
        var startBrowser: Bool?
        var urAccepted: Int?
    }

    struct Defaults: Codable {
        var device: DeviceConfig?
        var folder: FolderConfig?
    }
}

struct DBStatus: Codable {
    var globalBytes: Int?
    var globalFiles: Int?
    var inSyncBytes: Int?
    var inSyncFiles: Int?
    var state: String?
    var receiveOnlyChangedBytes: Int?
    var receiveOnlyChangedFiles: Int?
    var pullErrors: Int?
}

struct DBCompletion: Codable {
    var completion: Double?
    var globalBytes: Int?
    var needBytes: Int?
    var needFiles: Int?
}

struct SystemConnections: Codable {
    var connections: [String: ConnectionInfo]?

    struct ConnectionInfo: Codable {
        var connected: Bool?
        var address: String?
        var type: String?
    }
}

struct SystemStatus: Codable {
    var myID: String?
    var uptime: Int?
}

// MARK: - 客户端

/// 内核 loopback REST 客户端（仅同步会话期间存在——D-05）。
final class SyncthingREST {
    let baseURL: URL
    let apiKey: String
    private let session: URLSession

    init(port: Int, apiKey: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.network("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.network("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (data, http)
    }

    func systemStatus() async throws -> SystemStatus {
        let (data, _) = try await request("GET", "/rest/system/status")
        return try JSONDecoder().decode(SystemStatus.self, from: data)
    }

    func config() async throws -> FullConfig {
        let (data, _) = try await request("GET", "/rest/config")
        return try JSONDecoder().decode(FullConfig.self, from: data)
    }

    func saveConfig(_ config: FullConfig) async throws {
        let body = try JSONEncoder().encode(config)
        _ = try await request("PUT", "/rest/config", body: body)
    }

    func dbStatus(folder: String) async throws -> DBStatus {
        let (data, _) = try await request("GET", "/rest/db/status", query: ["folder": folder])
        return try JSONDecoder().decode(DBStatus.self, from: data)
    }

    func completion(device: String, folder: String) async throws -> DBCompletion {
        let (data, _) = try await request("GET", "/rest/db/completion", query: ["device": device, "folder": folder])
        return try JSONDecoder().decode(DBCompletion.self, from: data)
    }

    func connections() async throws -> SystemConnections {
        let (data, _) = try await request("GET", "/rest/system/connections")
        return try JSONDecoder().decode(SystemConnections.self, from: data)
    }
}

enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case notConsented
    case kernelStart(String)
    case remoteNotConnected
    case syncTimeout
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未完成同步配置"
        case .notConsented: return "尚未确认同步条款（冲突文件落库等）"
        case .kernelStart(let m): return "内核启动失败：\(m)"
        case .remoteNotConnected: return "远端设备不可达（检查远端是否在线、中继服务是否可用）"
        case .syncTimeout: return "同步超时（数据量较大或网络异常）"
        case .network(let m): return "网络错误：\(m)"
        }
    }
}
