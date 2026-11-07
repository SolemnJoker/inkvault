# Spec Delta: markdown-reading

## Purpose

将笔记渲染为正确的阅读视图，覆盖标准 Markdown 与项目允许的 Obsidian 常用扩展，并保证长文与大库的浏览性能。

## ADDED Requirements

### Requirement: 标准 Markdown 渲染

标题、列表、表格、任务列表、删除线、代码块 SHALL 按标准语义正确渲染（US-02）。

#### Scenario: 打开含常用元素的笔记

- **WHEN** 用户打开一篇含标题、列表、表格、任务列表、删除线与代码块的笔记的阅读视图
- **THEN** 上述元素均按其标准语义呈现

### Requirement: Obsidian 扩展渲染

`[[wikilink]]` SHALL 可跳转，`![[embed]]` 嵌入内容 SHALL 可见，YAML frontmatter SHALL 以属性表呈现，相对路径图片 SHALL 正确加载（US-02）。

#### Scenario: 含链接与嵌入的笔记

- **WHEN** 用户阅读含 `[[wikilink]]` 与 `![[embed]]` 的笔记
- **THEN** 点击链接跳转到目标笔记，嵌入内容在当前位置可见

#### Scenario: frontmatter 属性表

- **WHEN** 用户阅读一篇含 YAML frontmatter 的笔记
- **THEN** frontmatter 以属性表形式呈现而非原始文本

### Requirement: 扩展范围封闭

渲染扩展 SHALL 仅限 `[[`、`![[`、frontmatter、相对路径图片、Mermaid、KaTeX；MUST NOT 加载或执行任何第三方扩展代码（依据 D-02）。

#### Scenario: 未知语法按普通文本呈现

- **WHEN** 笔记包含项目不支持的自定义语法或第三方插件语法
- **THEN** 其按普通文本原样呈现，且不发生任何动态代码加载

### Requirement: Mermaid 与 KaTeX 懒加载渲染

Mermaid 与 KaTeX SHALL 采用懒加载离屏渲染且仅在可见时存活，滚出可见区即销毁，MUST NOT 常驻（依据 D-01 的唯一例外）。

#### Scenario: 滚动离屏后资源释放

- **WHEN** 包含 Mermaid 图或公式的一屏内容滚出可见区域
- **THEN** 其渲染资源被销毁，不再占用内存与 CPU

### Requirement: 阅读性能

超长笔记快速滚动 SHALL 无明显掉帧或空白滞留；约 1000 篇笔记的库冷启动到可阅读 MUST < 2s（US-02、NFR-02）。

#### Scenario: 超长笔记快速滚动

- **WHEN** 用户快速滚动一篇超长（含大量图片）的笔记
- **THEN** 无明显掉帧，不出现长时间空白滞留

#### Scenario: 大库冷启动

- **WHEN** 冷启动打开约 1000 篇笔记的 vault
- **THEN** 从启动到可以阅读一篇笔记不超过 2 秒
