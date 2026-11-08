# InkVault

iPad 原生 Markdown 笔记客户端：直接读写既有 Obsidian vault，主打低功耗；Vim 编辑 + Syncthing 手动跨网同步（自建私有中继）。

## 特性

- **直接打开现有 vault**（security-scoped bookmark，不复制、不污染 `.obsidian/`）
- **原生文本路径**渲染与编辑（禁 WebView；Mermaid/KaTeX 为 D-01 唯一例外：本地打包 JS + 离屏 WKWebView 快照，空闲即销毁，零网络）
- **Vim 模式**：normal/insert/visual、核心 motions/operators/计数、`/` `?` `n/N` `:s`
- **可靠保存**：防抖（800–2000ms 可配）+ 原子替换，保留创建时间；统一 VaultWriter + 操作日志
- **手动同步**：内嵌 Syncthing 内核，点击「同步」→ 启动 → 完成/超时 → 停止；进后台立即停
- **冲突可见**：`.sync-conflict-*` 标记、并排对比、保留本地/远端/都保留，解决后自动清理
- **功耗纪律**：前台静置零网络、后台零定时器/零扫描（无任何 UIBackgroundModes）

## 构建

- 仓库不含 `.xcodeproj`：CI 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成
- Go 内核：`go/kernel`（嵌入 [Syncthing](https://github.com/syncthing/syncthing) v1.30，gomobile 绑定面仅 Start/Stop/Version/MyDeviceID，全部配置经 127.0.0.1 REST 驱动）
- CI（`.github/workflows/ci.yml`）：
  1. `go-kernel`：Linux 上启动真实内核跑 REST 冒烟测试
  2. `ios`：macOS-15 构建 `SyncthingKernel.xcframework` → xcodegen → xcodebuild test（iPad 模拟器）→ 产出 **unsigned IPA**（Sideloadly/个人签名安装，NFR-06）

```bash
# 本地（macOS）
brew install xcodegen && xcodegen generate
open InkVault.xcodeproj
```

## 私有中继（D-06）

中继由需求方自有服务器承载（部署：`docker run syncthing/relaysrv -pools ""`，**不加入公共池**）。
首次配置向导中填入中继 URI 与远端设备 ID；参数不硬编码进代码。

## 文档

- `docs/requirements.md` — 需求基线 v1.0（US-01..US-13 / NFR-01..NFR-06）
- `docs/decisions.md` — 决策记录 v1.0（D-01..D-12）
- `openspec/` — 变更提案与能力规格（OpenSpec spec-driven 流程）
