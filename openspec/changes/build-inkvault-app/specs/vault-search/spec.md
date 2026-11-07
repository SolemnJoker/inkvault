# Spec Delta: vault-search

## Purpose

提供库内文件名与内容的按需检索，不建立常驻索引，守住功耗目标。

## ADDED Requirements

### Requirement: 按需检索

系统 SHALL 支持按文件名与目录内内容搜索，结果按需返回；MUST NOT 建立常驻索引，MUST NOT 在静置期进行文件扫描（US-11、NFR-03）。

#### Scenario: 文件名搜索

- **WHEN** 用户输入文件名关键词搜索
- **THEN** 按需返回匹配的文件列表

#### Scenario: 内容搜索

- **WHEN** 用户输入内容关键词搜索
- **THEN** 按需扫描返回匹配结果，搜索结束后不再有持续的文件扫描活动

### Requirement: 大库检索可用

约 2000 篇笔记的库上，搜索 SHALL 可用且不卡顿（US-11）。

#### Scenario: 大库搜索

- **WHEN** 在约 2000 篇笔记的 vault 中执行文件名或内容搜索
- **THEN** 界面不卡顿，结果可按需返回
