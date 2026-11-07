# Spec Delta: power-efficiency

## Purpose

跨切面资源纪律：保证前台静置近零开销、后台零活动，这是本项目立项动因（US-03）。

## ADDED Requirements

### Requirement: 前台静置零网络

App 前台打开且用户不输入时，静置 10 分钟 SHALL 无网络请求且 CPU 均值 < 2%（US-03、NFR-01）。

#### Scenario: 前台静置 10 分钟

- **WHEN** App 前台打开一篇笔记且用户 10 分钟内不进行任何输入
- **THEN** 期间无网络请求，CPU 平均占用 < 2%

### Requirement: 后台零活动

用户退出 App（且非同步进行中）后，息屏 1 小时 SHALL 无后台网络活动、无定时任务、无文件扫描（US-03、NFR-03）。

#### Scenario: 息屏 1 小时

- **WHEN** 用户完成一次编辑并退出 App，息屏 1 小时
- **THEN** 期间无后台网络活动、无定时唤醒、无文件扫描

### Requirement: 编辑不异常发热

连续输入 10 分钟 SHALL 不出现异常发热，能耗与同类原生笔记应用相当（US-03）。

#### Scenario: 连续输入 10 分钟

- **WHEN** 用户连续输入 10 分钟
- **THEN** 设备无异常发热，能耗与同类原生笔记应用相当
