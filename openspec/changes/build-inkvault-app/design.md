# Design

## Context

全新项目（空仓库），动机与范围见 proposal.md；行为契约见 specs/。技术边界已被基线文档锁定：docs/decisions.md D-01..D-12 是硬约束，本文不得与之冲突，只做架构综合与补充。核心约束：iPad only（NFR-05）、低功耗立项（D-01/D-05）、无插件（D-02）、手动同步（D-05）。

## Goals / Non-Goals

**Goals:**

- 单体 iOS App 的分层架构：SwiftUI 壳 + 原生文本核心 + 嵌入式同步内核
- 用三个 Spike 前置消除最高技术风险（bookmark、输入法、内嵌内核），回填 T-01..T-05
- 为未来 M6（版本历史）保留零成本接缝（D-09），本期不实现（D-12）

**Non-Goals:**

- 插件系统与动态代码加载（D-02）；后台同步与任何常驻活动（D-05）
- 版本历史 UI 与回滚（D-12）；iPhone / Mac Catalyst（NFR-05）；App Store 分发（NFR-06）
- 自研渲染引擎级 vim 全量模拟（本期 vim 范围已由需求方锁定：核心编辑集 + 搜索替换）

## Decisions

### 1. 分层架构

```
SwiftUI 壳（导航/文件树/设置/冲突对比 UI）
  ↓
应用服务层（VaultSession、保存防抖编排、同步生命周期编排、外部变更检测）
  ↓
核心服务（VaultWriter ｜ Markdown 解析/高亮 ｜ Vim 引擎 ｜ Syncthing 内核绑定）
```

- 编辑核心为 UITextView 子类承载自研 buffer，SwiftUI 只做外壳与列表（D-03 明确禁止 TextEditor 承载正文）
- 替代方案：全文 WebView 渲染、SwiftUI TextEditor — 均被 D-01/D-03 以功耗与击键性能否决，不再评估

### 2. Markdown 处理链

- 自研增量解析：行级块结构 + 行内 span，产出一棵轻量 AST；阅读视图排版与编辑器语法高亮共享同一解析器，编辑时仅对变更行增量重解析（支撑 NFR-02：1MB 单文件击键 P95 < 8ms）
- 阅读视图为原生排版（TextKit/自绘混合）； wikilink/embed/frontmatter 属性表均为原生控件
- Mermaid/KaTeX：WKWebView 离屏渲染为位图快照后即销毁，仅在可见时持有（D-01 的唯一例外）；实现选型在 M5 前细化

### 3. 写盘与并发控制

- 所有 vault 写入统一经 VaultWriter：临时文件 + 原子替换，替换后回写创建时间/权限；预留 hook 点，沙盒内维护 append-only 操作日志（时间、文件、变更类型、前后大小），不写入 vault（D-09）
- 保存防抖默认 1000ms，设置页可配 800–2000ms；进后台/挂起前强制 flush（D-10、US-04）
- 外部变更检测（US-10）：仅对打开中的笔记做前台轻量轮询（mtime+size 比对）+ 保存前强制比对，不做常驻监听（D-05 禁止的是"常驻"，前台轮询随场景销毁）

### 4. 同步架构（依据 D-05/D-06/D-07）

- Go 版 Syncthing 内核经 gomobile 编译为 xcframework 嵌入；生命周期由应用层编排：用户点击"同步" → start → 等待完成或超时 → stop；scenePhase 离开前台立即 stop 并取消网络
- 配置、证书、设备密钥存 App 沙盒，API Key 等敏感项进 Keychain；绝不落 vault（D-07）
- 中继地址、端口、限速、超时等全部为配置项（首次配置向导导入，T-01/T-02 由 Spike C 实测回填）；关闭全局发现与公共中继池；保留本地发现以支持局域网直连（跨网才走自建中继）
- 冲突文件（`.sync-conflict-*`）为内核行为，接受落库：首次开启同步时征得同意；App 内标记、对比、解决后清理败方文件（需求方确认策略，对应 sync-conflicts 规格）

### 5. Spike 前置策略

三个 Spike 作为实施第一批，产出直接回填 docs/decisions.md 附录 A：

- **Spike A**（bookmark）：后台/重启后 security-scoped bookmark 可用性 → T-04
- **Spike B**（输入法）：程序化切换输入法与 normal 模式按键拦截的可达程度 → T-05
- **Spike C**（内嵌内核）：按需生命周期稳定性、经自建中继的连通成功率、资源释放、忽略规则是否必须落盘 → T-01/T-02/T-03

任一 Spike 触发对应决策的推翻条件 → 停止实现，携数据上报需求方（D-04/D-05/D-06）。

### 6. 工程结构

- 单 Xcode 项目；Swift 依赖用 SPM，Go 内核以预编译 xcframework 引入（带构建脚本可复现）
- 分层可单测：vim 引擎、markdown 解析器、VaultWriter 为纯逻辑模块，XCTest 覆盖；NFR 指标（击键 P95、冷启动、同步资源）用 XCTest measure + 实测台账（需求覆盖矩阵 M5 收尾填写）
- vault 注册表（bookmark 数据 + 显示名）存沙盒；文件树目录懒加载枚举，不预扫全库

## Risks / Trade-offs

- [内嵌内核在按需生命周期下不稳定/资源不释放] → Spike C 前置实测；失败则按 D-05 推翻条件评估直连或自研同步，须新增决策记录
- [bookmark 失效率过高] → Spike A 实测；备选"沙盒工作副本 + 显式回写"，须重估 US-01 验收（D-04）
- [输入法自动切换不可达] → US-06 本就是最佳努力；Spike B 只回填 T-05 与文案，不阻塞
- [自研 markdown/vim 工作量偏大] → 范围已锁定（扩展封闭 D-02；vim 核心+搜索替换）；解析器阅读/编辑共享降低双份成本
- [长文击键 P95 不达标] → 增量解析 + 避免全文重排；仍不达标则触发 D-03 推翻条件，须先出性能对比数据
- [前台轮询检测外部变更存在窗口期] → 接受：同步为手动语义（D-05），外部变更仅发生在同步窗口，保存前强制比对兜底

## Migration Plan

全新项目，无数据迁移。顺序：Spike A/B/C → 回填待定项 → 按层实施 → NFR 实测台账 → 需求覆盖矩阵收尾。无回滚问题（不覆盖任何既有系统）。

## Open Questions

- T-01..T-05：由对应 Spike 实测回填，不阻塞 M1/M2 层的开发（中继参数仅影响同步模块配置项）
- Mermaid/KaTeX 离屏渲染的具体选型（快照方案细节）：M5 前定，不影响本期架构
