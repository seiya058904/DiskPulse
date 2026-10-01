# DiskPulse

<img width="1672" height="941" alt="project-diskpulse" src="https://github.com/user-attachments/assets/4b06b439-eb31-4c4f-9e0e-f17e7529a342" />

DiskPulse 是一个零依赖、离线运行的 Windows 磁盘容量与目录变化看板。

项目图标同时用于 Windows 程序、安装器、快捷方式和浏览器看板标签页。

双击 `check.bat` 后，程序会读取本地固定磁盘容量，保存历史记录，并在脚本旁的 `runtime/` 中生成自包含 HTML 报告。报告保留容量总览、使用率状态、趋势和满盘预测，并在建立基线后定位一级、二级目录的增长与释放。

## 使用方法

普通用户请下载 GitHub Release 中最新的 `DiskPulse-Setup-*.exe`（带版本号）安装包并运行。安装程序会在当前用户目录创建程序、桌面快捷方式和开始菜单入口，不需要管理员权限。安装后双击 `DiskPulse`，点击“扫描磁盘”即可；扫描完成后会自动用默认浏览器打开看板。

| 入口 | 说明 |
|------|------|
| `DiskPulse.vbs` | **普通运行**（推荐）。无终端窗口，后台扫描，完成后自动打开浏览器报告。 |
| `check.bat` | **调试运行**。显示终端进度，供开发和排查问题使用。 |
| `check-profile.bat` | **性能诊断**。显示终端并在 `runtime/` 中生成 `last-profile.json`，仅用于开发。 |
| `configure-ai.bat` | **AI 配置**（可选）。交互式配置 AI 分析功能，详见下方说明。 |

程序文件默认安装到 `%LOCALAPPDATA%\DiskPulse`，历史记录、快照、报告、日志和 AI 配置保存到 `%LOCALAPPDATA%\DiskPulse\data\runtime`。升级程序不会覆盖这些数据；卸载时默认保留历史数据。

开发者可在项目根目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File build-installer.ps1`，生成 `dist\` 下带版本号的安装包。NSIS 可通过 `-NsisPath`、`DISKPULSE_NSIS_PATH`、PATH 中的 `makensis.exe` 或标准安装位置解析；没有可用编译器时脚本会明确报告尝试过的路径。

`check.bat` 是从 `src/` 生成的运行时工件。开发者修改 `src/` 后运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-check.ps1` 重新生成；不要直接手改 `check.bat` 中的应用代码段。

开发者完整验证使用统一入口：

```powershell
# 核心验证（本机没有 NSIS 时会跳过安装包构建）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1

# 包含安装包构建的完整验证（需要 NSIS）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1 -IncludeInstaller
```

需要单独调试时仍可直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-DiskPulseTestSuite.ps1
pwsh -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
pwsh -NoProfile -File tests\DiskPulse.Phase4.Tests.ps1
```

代码完成不会自动发布版本。完成测试和真实浏览器 QA 后，应先提出目标 SemVer、版本类型和摘要，并获得针对该版本的明确发布授权；未授权时不会创建 tag 或 GitHub Release。

首次运行建立每个磁盘的目录基线；后续运行显示目录变化、解释率、扫描完整性、预期排除和无法访问路径。

目录快照与容量 CSV 保存 Windows 卷 GUID。只有盘符、扫描根路径和已确认的卷身份一致时，历史才可参与当前卷比较；其他卷复用盘符时重新建立基线。旧版无 GUID 的记录及身份查询失败的记录仍保留在原 CSV/快照中（沿用原保留策略），但不会被推测为同一卷，也不参与可靠变化、容量趋势、满盘预测或 AI 变化证据。身份查询恢复后，从已确认的同卷基线继续比较。卷 GUID 仅保存在本地报告/历史中，不发送给 AI；AI 数据只携带每次分析重新分配的卷引用（如 volume-1）、身份确认状态及可比较性。不可比较的容量差量和解释率保持 null，不用零值冒充测量结果。

核心磁盘扫描与报告生成完全离线；只有用户主动启用并配置 AI 后，才会访问所配置的 AI API 发送脱敏数据。程序不会读取文件内容，也不会追踪单个文件或自动删除用户文件。

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
2. 选择服务商预设：DeepSeek、小米 MiMo、阿里云百炼/Qwen 或 OpenAI
3. 输入 API Key；接口地址和默认模型会自动填写
4. 设置超时时间

也可以选择“自定义兼容接口”，手动输入 API Endpoint 和模型名称。预设使用 OpenAI 兼容的 Chat Completions 接口；厂商的 API Key 需要用户自行申请，DiskPulse 不提供 API 额度。

当前预设：

| 服务商 | 默认接口 | 默认模型 |
|------|------|------|
| DeepSeek | `https://api.deepseek.com` | `deepseek-v4-flash` |
| 小米 MiMo | `https://api.xiaomimimo.com/v1` | `mimo-v2.5-pro` / `mimo-v2.5` |
| 阿里云百炼/Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen3.7-plus` |
| OpenAI | `https://api.openai.com/v1` | `gpt-5.4-mini` |

配置保存在用户数据目录的 `runtime/ai-config.local.json`，API Key 使用当前 Windows 用户的 DPAPI 加密，不会以明文形式存储。

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

### 无需 API 也能用 AI（手动复制）

AI 数据分析的生成与 API 发送是解耦的：只要本轮扫描存在可靠的目录变化，DiskPulse 就会生成同一份脱敏分析数据。即使你没有配置任何 API，也可以在报告的 "AI 变化解释" 区域点击**「复制给 AI」**，一键把这份数据粘贴到 ChatGPT、Claude、Gemini、DeepSeek 等任意 AI 中使用；复制内容只包含脱敏后的目录变化、容量变化、历史趋势和扫描完整性统计，不包含 API Key。

- AI 自动分析等待期间，页面会在后台每 2 秒探测结果；完成后在多数浏览器直接更新 AI 区域，不需要手动刷新。对本地文件缓存较严格的浏览器（Edge/Chrome）会在约 10 秒后自动刷新一次显示结果，之后最多再退避 20s/30s 两次，不再反复整页刷新。
- 自动分析成功后，可用**「复制 AI 结果」**把分析结论复制出去；使用 **「复制磁盘摘要」**可复制本轮磁盘容量摘要。
- 当 AI 未配置、未启用或自动分析失败时，**「复制给 AI」**仍然可用——手动复制是正式 fallback，不会因为 API 出问题而一无所获。

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

最近一次扫描的 AI 状态或分析结果保存在用户数据目录的 `runtime/last-ai-analysis.json`，用于排查问题，包含状态、模型名和分析内容（或错误类别），不包含 API Key 或 endpoint。
