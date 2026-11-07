import Foundation

/// 可取消的防抖器：stop 后触发一次闭包。
/// 功耗纪律（D-05/NFR-03）：flush() 供进后台前强制落盘；deinit 自动 flush。
final class Debouncer {
    var interval: TimeInterval
    private var workItem: DispatchWorkItem?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func bounce(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// 立即执行未触发的闭包（进后台/挂起前调用，D-10）。
    func flush() {
        guard let item = workItem, !item.isCancelled else { return }
        workItem = nil
        item.cancel()
        item.perform()
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    var isPending: Bool { workItem != nil && workItem?.isCancelled == false }
}
