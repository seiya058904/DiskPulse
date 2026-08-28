# DiskPulse Design

本文件记录当前看板的设计约束，是当前 UI/设计约束的权威说明。历史设计过程如需追溯，可参考 `docs/superpowers/plans/2026-07-13-dashboard-visual-hierarchy.md`；本文不依赖本地未跟踪文件。

## Direction

- 产品型系统工具界面，面向普通 Windows 用户。
- 浅色与深色都保持克制、高对比、低装饰。
- 语义色只用于容量、可靠性、提醒和严重状态。
- 视觉特色来自清晰的数据构图，不来自动画、霓虹或玻璃效果。

## Information Order

页头 → 快捷导航 → 整体总览 → 关注中心 → 本次变化 → 磁盘容量与使用率 → 历史对比 → 磁盘详情 → 扫描信息。

## Interaction

- 使用原生按钮、选择框、详情折叠和锚点导航。
- 动画仅用于 150–180ms 的状态反馈，并尊重 `prefers-reduced-motion`。
- 图表必须同时提供文字摘要；未知或无效数据不参与可靠结论。
- 移动端保持单列、44px 触控目标和无横向页面滚动。

## Implementation Constraints

- PowerShell 5.1、核心运行时单文件 `check.bat`、离线、零依赖。
- 不修改 CSV、快照 JSON、目录比较、基线、保留或告警阈值。
- 动态扫描内容通过 JSON 和安全 DOM API 渲染。
