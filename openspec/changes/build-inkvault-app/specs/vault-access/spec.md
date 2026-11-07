# Spec Delta: vault-access

## Purpose

管理 vault 目录的授权、打开与库保护语义：直接读写既有 Obsidian vault 而不复制、不污染，支持多 vault 与授权失效恢复。

## ADDED Requirements

### Requirement: 打开现有 vault 不复制

用户首次选择 vault 目录并授权后，系统 SHALL 直接读写该目录，MUST NOT 产生整库副本（依据 D-04）。

#### Scenario: 首次授权打开

- **WHEN** 用户在 App 中首次选择已有 vault 文件夹并完成授权
- **THEN** App 直接读写该目录，且沙盒内不出现该库的副本

#### Scenario: 重启后免重选

- **WHEN** 用户授权打开某 vault 后完全退出并重新启动 App
- **THEN** 该 vault 无需重新选择目录即可打开

### Requirement: 多 vault 管理

系统 SHALL 支持添加与切换多个 vault；切换后文件树与内容随之切换，且各 vault 的授权 MUST 保持有效。

#### Scenario: 切换 vault

- **WHEN** 用户拥有多个 vault 并在库之间切换
- **THEN** 文件树与笔记内容切换到目标 vault，且之后再切回时其他 vault 的授权仍然有效

### Requirement: 授权失效恢复

授权失效（目录被移动、权限丢失）时，系统 SHALL 明确提示并引导重新授权，MUST NOT 静默失败，MUST NOT 丢失未保存内容（US-01）。

#### Scenario: 目录被移动后进入 vault

- **WHEN** vault 目录被移动导致授权失效，用户再次进入该 vault
- **THEN** App 给出明确的失效提示与重新授权引导，且用户在此前的未保存编辑内容在重新授权后可恢复

### Requirement: 配置目录严格只读

对 vault 内 `.obsidian/` 目录，系统 MUST 只读：不写入、不修改、不删除其中任何内容（依据 D-04）。

#### Scenario: 保存笔记后检查配置目录

- **WHEN** 用户在 App 中编辑并保存任意笔记
- **THEN** `.obsidian/` 内所有文件的内容、数量与修改时间均无变化

### Requirement: 内部目录默认隐藏

文件树 SHALL 默认不展示 `.obsidian/`、`.trash/`、`.git/` 等内部目录；`.trash/` 的删除语义与 Obsidian 保持一致（依据 D-04）。

#### Scenario: 浏览文件树

- **WHEN** 用户浏览 vault 文件树
- **THEN** 默认看不到 `.obsidian/`、`.trash/`、`.git/` 等内部目录
