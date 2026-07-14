# DiskPulse

<img width="1672" height="941" alt="project-diskpulse" src="https://github.com/user-attachments/assets/4b06b439-eb31-4c4f-9e0e-f17e7529a342" />

DiskPulse 是一个零依赖、离线运行的 Windows 磁盘容量与目录变化看板。

双击 `check.bat` 后，程序会读取本地固定磁盘容量，保存历史记录，并在脚本旁的 `runtime/` 中生成自包含 HTML 报告。报告保留容量总览、使用率状态、趋势和满盘预测，并在建立基线后定位一级、二级目录的增长与释放。

## 使用方法

| 入口 | 说明 |
|------|------|
| `DiskPulse.vbs` | **普通运行**（推荐）。无终端窗口，后台扫描，完成后自动打开浏览器报告。 |
| `check.bat` | **调试运行**。显示终端进度，供开发和排查问题使用。 |
| `check-profile.bat` | **性能诊断**。显示终端并在 `runtime/` 中生成 `last-profile.json`，仅用于开发。 |
| `configure-ai.bat` | **AI 配置**（可选）。交互式配置 AI 分析功能，详见下方说明。 |

首次运行建立每个磁盘的目录基线；后续运行显示目录变化、解释率、扫描完整性、预期排除和无法访问路径。

运行数据只保存在 `runtime/`，不会联网。程序不会读取文件内容，也不会追踪单个文件或自动删除用户文件。

## 环境

- Windows
- Windows PowerShell 5.1 或更高版本
- 无需安装 Node.js、Python 或其他依赖

## 扫描边界

目录扫描只聚合根目录文件、一级目录和二级目录。Reparse Point、Junction、符号链接、`System Volume Information` 与 `$RECYCLE.BIN` 会被排除。无法访问的范围会在报告中标记，部分扫描不会覆盖该磁盘最近的完整基线。

## 可选 AI 分析功能

DiskPulse 提供可选的 AI 磁盘变化解释功能。**AI 默认关闭**，不启用时不影响任何现有功能。

### 启用 AI

运行 `configure-ai.bat` 进入交互式配置菜单：

1. 选择 "Enable and configure AI"
2. 输入 API Endpoint（远程必须使用 HTTPS，localhost/127.0.0.1/::1 可使用 HTTP）
3. 输入模型名称
4. 输入 API Key（本地接口可选）
5. 设置超时时间

配置保存在 `runtime/ai-config.local.json`，API Key 使用当前 Windows 用户的 DPAPI 加密，不会以明文形式存储。

### 工作原理

启用后，DiskPulse 在完成目录扫描和变化比较后，会将以下脱敏数据发送到用户配置的 AI 接口：

- 脱敏后的目录路径（用户目录替换为 `%USERPROFILE%`）
- 目录变化量（增长/释放）
- 磁盘容量变化
- 历史趋势分类
- 扫描完整性统计

**不会发送：**
- 文件内容
- 完整的用户目录路径
- API Key
- 磁盘硬件信息

AI 解释结果会注入到 HTML 报告的 "AI 变化解释" 区域。

### 隐私说明

- **本地报告**：HTML 报告中可能显示本机真实目录路径（如 `C:\Users\用户名\Downloads`），这是正常的本地数据显示。
- **发送给 AI 的数据**：路径经过脱敏处理，`C:\Users\admin\Documents` 会变为 `%USERPROFILE%\Documents`。
- **AI 解释属于推测**：模型返回的分析仅供参考，不能替代原始磁盘数据本身。
- **AI 失败不影响报告**：即使 AI 请求失败，磁盘扫描和 HTML 报告仍正常生成。

### 兼容接口

支持标准 OpenAI-compatible Chat Completions 接口。本地模型可使用 LM Studio、Ollama 等提供兼容接口的工具，但不保证所有第三方"兼容接口"都完全兼容。

### 禁用和删除

- 在 `configure-ai.bat` 菜单中选择 "Disable AI" 可禁用（保留配置）
- 选择 "Delete AI configuration" 可删除配置文件
- 禁用后运行普通扫描，AI 区域会显示 "AI 分析未启用"

### 结果文件

最近一次扫描的 AI 状态或分析结果保存在 `runtime/last-ai-analysis.json`，用于排查问题，包含状态、模型名和分析内容（或错误类别），不包含 API Key 或 endpoint。
