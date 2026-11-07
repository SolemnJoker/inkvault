import Foundation
import SyncthingKernel

/// Go 内核绑定面。gomobile 生成的是 C 形式接口：
/// `BOOL KernelStart(NSString*, long, NSString*, NSError**)` 等，手动转为 throws。
/// 所有跨语言调用集中在此文件，便于接口名对齐修正。
enum KernelBridge {
    static var version: String {
        KernelVersion()
    }

    static var isRunning: Bool {
        KernelIsRunning()
    }

    static var myDeviceID: String {
        KernelMyDeviceID()
    }

    static func start(homeDir: URL, guiPort: Int, apiKey: String) throws {
        var err: NSError?
        let ok = KernelStart(homeDir.path, guiPort, apiKey, &err)
        if !ok {
            throw err ?? CocoaError(.featureUnsupported,
                userInfo: [NSLocalizedDescriptionKey: "内核启动失败（无错误信息）"])
        }
    }

    static func stop() throws {
        var err: NSError?
        let ok = KernelStop(&err)
        if !ok, let err {
            throw err
        }
    }
}
