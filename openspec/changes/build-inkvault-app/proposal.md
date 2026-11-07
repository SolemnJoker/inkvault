# Proposal

## Why

需求方已在桌面端使用 Obsidian，但现有移动端方案与核心目标冲突：插件常驻与后台同步带来功耗与不稳定问题（依据 D-02、D-05）。需要一个 iPad 原生 Markdown 客户端：直接读写现有 vault、息屏近零耗电、支持 Vim 编辑与手动跨网同步。本变更为全应用整体奠基提案（粗粒度），覆盖需求基线 US-01..US-13 / NFR-01..NFR-06，后续按里程碑拆分为增量变更。

## What Changes

- 全新 iPad 应用（iPadOS 17+，仅 iPad；个人/企业签名分发，非 App Store，依据 NFR-05/NFR-06）
- 通过 security-scoped bookmark 直接打开现有 Obsidian vault，不产生副本，多 vault 支持，授权失效有引导（US-01）
- 库保护语义：`.obsidian/` 严格只读、内部目录默认隐藏、写入 vault 的同步产物须显式同意（US-09、依据 D-04/D-08）
- 原生文本路径阅读渲染：标准 Markdown + `[[`、`![[`、frontmatter、相对路径图片；Mermaid/KaTeX 采用懒加载离屏渲染且仅在可见时存活（US-02、依据 D-01）
- 编辑核心：UITextView 子类 + 自研 buffer，800–2000ms 可配置防抖 + 临时文件原子替换写盘，统一经 VaultWriter 并记录沙盒操作日志；外部变更保护（US-04、US-10，依据 D-03/D-09/D-10）
- Vim 模式：normal/insert/visual，核心 motions/operators + 计数前缀 + 搜索替换（`/` `?` `n/N` `:s`）；中文输入最佳努力（US-05、US-06）
- 嵌入 Syncthing 内核的手动同步：用户触发 → 启动 → 同步 → 停止，进入后台立即停止内核；自建私有中继，禁公共中继池与全局发现；凭证只存沙盒/Keychain（US-07、US-12，依据 D-05/D-06/D-07）
- 冲突可见：`.sync-conflict-*` 文件落库（首次开启同步时征得同意）、App 内标记与对比、解决后自动清理败方文件（US-08）
- 全局资源纪律：前台静置零网络请求、后台/息屏零定时器零网络零扫描（US-03、NFR-01/NFR-03）

## Capabilities

### New Capabilities

- `vault-access`: vault 目录授权与打开（bookmark 持久化、多 vault、失效恢复）与库保护语义（不复制、`.obsidian/` 只读、内部目录隐藏）— US-01、US-09
- `markdown-reading`: 阅读渲染（标准 Markdown 与 Obsidian 常用扩展、frontmatter 属性表、图片）与长文滚动性能 — US-02、NFR-02（冷启动）
- `markdown-editing`: 可靠编辑（防抖原子保存、崩溃不丢内容、后台前落盘）、外部变更保护、VaultWriter 写盘统一入口与操作日志 — US-04、US-10、NFR-02（击键）
- `vim-mode`: Vim 模式语义（normal/insert/visual、核心命令与计数、搜索替换、模式指示）与中文输入最佳努力支持 — US-05、US-06
- `vault-search`: 文件名与内容按需检索，不建常驻索引 — US-11（检索部分）
- `sync`: 手动跨网同步（内核按需生命周期、结果报告、失败分类、蜂窝确认）、自建中继配置、凭证与配置仅存沙盒、元数据披露 — US-07、US-12、NFR-04
- `sync-conflicts`: 冲突文件标记、双版本对比与取舍（保留本地/远端/都保留）、解决后清理 — US-08
- `power-efficiency`: 跨切面资源纪律（前台静置 CPU < 2% 且零网络、后台零定时器/网络/文件扫描、同步结束资源完全释放）— US-03、NFR-01/NFR-03

### Modified Capabilities

（无 — 全新项目，无既有能力规格）

## Impact

- **代码**：全新 Xcode 项目。SwiftUI（导航/列表/设置外壳）+ UIKit UITextView 子类（编辑核心，依据 D-03）+ Go/Syncthing 内核经 gomobile 绑定嵌入（依据 D-05）
- **外部系统**：需求方自有公网服务器承载中继（strelaysrv），参数由 Spike C 实测回填 T-01/T-02 后以配置项导入，不硬编码（依据 D-06）
- **风险**：三个 Spike 前置验证 — A（bookmark 后台/重启可用性，回填 T-04）、B（输入法自动切换程度，回填 T-05）、C（内嵌内核按需生命周期与中继连通性）；任一失败触发对应决策的推翻条件，须停下与需求方重估
- **依赖**：Syncthing Go 内核；无插件系统、无第三方云服务（依据 D-02/D-07）
- **约束**：所有实现与决策记录 D-01..D-12 冲突时停止并上报；性能验收以 NFR 编号为准
