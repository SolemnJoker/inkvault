# Spec Delta: vim-mode

## Purpose

在编辑器中提供 Vim 模式语义（本期范围：核心编辑集 + 搜索替换，经需求方确认）与中文输入最佳努力支持，服务外接键盘高效写作。

## ADDED Requirements

### Requirement: 模式与核心命令

编辑器 SHALL 支持 normal/insert/visual（v/V）模式，以及 motions（h/j/k/l/w/b/e/0/^/$/gg/G）、operators（d/c/y/p/x）与计数前缀（如 3dd）、进入插入（i/a/o/A/I）、撤销重做（u/Ctrl-r），作用语义与 vim 一致（US-05）。

#### Scenario: normal 移动与删除

- **WHEN** 用户在 normal 模式下按 h/j/k/l 移动、w/b 按词移动、dd 删除整行
- **THEN** 光标与文本按 vim 语义变化

#### Scenario: 计数前缀

- **WHEN** 用户使用计数前缀（如 3dd、2dw）
- **THEN** 作用范围与 vim 一致

### Requirement: 搜索与替换

编辑器 SHALL 支持 `/`、`?`、`n/N` 搜索导航与 `:s` 替换（需求方确认范围）。

#### Scenario: 搜索并替换

- **WHEN** 用户以 `/` 向下搜索并执行 `:s` 替换
- **THEN** 光标按 vim 语义定位到匹配项，替换按确认范围生效

### Requirement: 模式指示

当前编辑模式 SHALL 在界面上清晰可见（US-05）。

#### Scenario: 模式切换指示

- **WHEN** 用户在 normal/insert/visual 之间切换
- **THEN** 界面上的模式指示随当前模式更新

### Requirement: insert 模式不被拦截

进入 insert 模式后输入文本 SHALL 正常插入且按键不被 vim 命令层拦截（US-05）。

#### Scenario: insert 输入

- **WHEN** 用户按 i/a/o 进入 insert 模式并输入文本
- **THEN** 文本正常插入，字母按键不会触发 vim 命令

### Requirement: 中文输入最佳努力

进入 insert 时若当前输入法非中文，系统 SHALL 给出轻量提示或引导并在能力允许时尝试切换（不承诺成功）；normal 模式下外接键盘按键 SHALL 由 App 处理、不触发输入法候选；系统限制导致无法自动切换时，设置页 SHALL 说明 App 实际做到的程度（US-06）。

#### Scenario: insert 提示切换

- **WHEN** 用户在输入法为英文时进入 insert 模式
- **THEN** 出现轻量提示或引导，且在系统能力允许时尝试切换输入法；无法切换时不阻塞输入

#### Scenario: normal 按键不触发候选

- **WHEN** 用户在 normal 模式下使用外接键盘按键
- **THEN** 按键由 App 处理，不触发输入法候选窗
