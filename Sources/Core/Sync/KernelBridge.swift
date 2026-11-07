import Foundation
import SyncthingKernel

/// Go 内核绑定面（gomobile 生成：Kernel<Name> 全局函数）。
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

    static func start(homeDir: URL, guiPort: Int32, apiKey: String) throws {
        try KernelStart(homeDir.path, guiPort, apiKey)
    }

    static func stop() throws {
        try KernelStop()
    }
}
