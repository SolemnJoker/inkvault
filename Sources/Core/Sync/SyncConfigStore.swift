import Foundation

/// 同步配置（非机密项）：存沙盒 JSON。API Key 存 Keychain（D-07）。
struct SyncSettings: Codable {
    /// 自建私有中继 URI，例如 relay://relay.example.com:6785/?id=XXXXXXXX-XXXXXXX（首次配置向导中填写，不硬编码）
    var relayURI: String = ""
    /// 远端设备 ID（桌面端 Syncthing 设备）
    var remoteDeviceID: String = ""
    /// 远端名称（显示用）
    var remoteName: String = ""
    /// 冲突文件落库同意（D-08 / 需求方确认策略）
    var conflictConsentGiven: Bool = false
    /// .stfolder 标记目录同意（同步产物写入 vault 的显式授权）
    var stfolderConsentGiven: Bool = false
    /// GUI/API 端口（loopback）
    var apiPort: Int = 18384
}

final class SyncConfigStore: ObservableObject {
    static let shared = SyncConfigStore()
    static let syncAPIKeychainKey = "inkvault.sync.apikey"
    static let folderID = "inkvault-vault"

    @Published var settings: SyncSettings {
        didSet { persist() }
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.syncConfig),
           let s = try? JSONDecoder().decode(SyncSettings.self, from: data) {
            settings = s
        } else {
            settings = SyncSettings()
        }
    }

    var isConfigured: Bool {
        !settings.relayURI.isEmpty && !settings.remoteDeviceID.isEmpty
    }

    var consentGiven: Bool {
        settings.conflictConsentGiven && settings.stfolderConsentGiven
    }

    /// 内核 REST API Key（首次生成，入 Keychain）。
    var apiKey: String {
        if let existing = KeychainStore.get(Self.syncAPIKeychainKey) { return existing }
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let key = Data(bytes).base64EncodedString()
        KeychainStore.set(key, for: Self.syncAPIKeychainKey)
        return key
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: AppPaths.syncConfig, options: .atomic)
        }
    }
}
