# DiskPulse 可选 AI 磁盘变化解释设计

日期：2026-07-14
状态：已完成方案讨论，待用户审阅
目标版本：建议作为独立小版本功能加入
仓库：`seiya058904/DiskPulse`

## 1. 背景

DiskPulse 当前能够可靠地完成以下工作：

- 扫描本地固定磁盘；
- 保存容量历史；
- 对比最近完整基线；
- 展示一级、二级目录的增长与释放；
- 识别持续增长、持续释放、本次突增、首次出现等趋势；
- 标明扫描是否完整以及无法访问的范围；
- 生成离线、自包含 HTML 报告。

当前报告能够回答“哪里增长了”，但无法充分回答普通用户最关心的问题：

> 为什么这里突然增长了？这通常代表什么？我应该处理还是继续观察？

本功能引入一个**可选的 AI 分析阶段**。DiskPulse 将已有的可靠目录变化、容量变化和历史趋势整理为脱敏后的结构化数据，通过用户自行配置的 OpenAI-compatible API 发送给模型，再把模型返回的解释写入报告。

AI 是附加解释层，不参与扫描、比较、趋势计算和自动清理。

---

## 2. 设计目标

### 2.1 核心目标

扫描完成后，DiskPulse 自动完成以下流程：

1. 汇总本次可靠的新增、增长、释放和历史趋势；
2. 对路径与用户信息进行脱敏；
3. 调用用户配置的 AI API；
4. 解析模型返回结果；
5. 将解释注入本次 HTML 报告；
6. 将本次结果保存到本机运行目录，便于排查。

### 2.2 约束

必须满足：

- AI 默认关闭；
- 未配置 AI 时，现有 DiskPulse 行为基本不变；
- 不引入 Node.js、Python、SDK、数据库或后台服务；
- 使用 PowerShell 自带 HTTP 能力；
- 保持 Windows PowerShell 5.1+ 兼容；
- 不修改现有扫描深度；
- 不读取文件内容；
- 不发送单个文件内容；
- AI 请求失败不能导致扫描失败；
- API Key 不进入 HTML、日志、快照或 Git；
- 远程请求只发送脱敏后的目录统计与趋势数据。

### 2.3 非目标

第一版不实现：

- 浏览器直接调用 API；
- 本地 HTTP Bridge；
- 聊天窗口；
- 流式输出；
- 自动清理或删除；
- AI 自动执行 PowerShell 命令；
- 文件内容分析；
- 单文件级追踪；
- 在线搜索目录对应的软件；
- 供应商专属 SDK；
- 将 AI 结果纳入历史趋势算法；
- 对不同 API 厂商维护大量专属逻辑。

---

## 3. 总体架构

现有扫描流程保持不变，只在报告生成前增加一个独立、可失败的 AI 阶段。

```text
扫描固定磁盘
  ↓
保存当前快照
  ↓
与最近完整基线比较
  ↓
生成目录变化和历史趋势
  ↓
构造脱敏 AI 输入
  ↓
检查 AI 配置与调用条件
  ↓
可选：调用 OpenAI-compatible API
  ↓
解析并保存 AI 结果
  ↓
把结果注入 HTML
  ↓
打开报告
```

AI 阶段必须被独立的 `try/catch` 包裹。任何配置、网络、认证、额度、超时或模型格式错误，都只能改变 AI 区域的状态，不能中断磁盘报告生成。

---

## 4. 运行文件与改动范围

### 4.1 修改文件

核心改动：

- `check.bat`
- `tests/DiskPulse.Phase3.Tests.ps1`
- `tests/DiskPulse.Phase4.Tests.ps1`
- `README.md`
- `CLAUDE.md`
- `AGENTS.md`

新增：

- `configure-ai.bat`

### 4.2 不修改的核心内容

第一版不改：

- C# 目录扫描器的遍历策略；
- 一级、二级目录聚合边界；
- 快照的现有核心字段；
- 基线选择规则；
- 历史快照保留规则；
- 容量状态阈值；
- 当前趋势分类算法；
- `DiskPulse.vbs` 的普通启动方式。

---

## 5. 配置模式

### 5.1 配置入口

新增：

```text
configure-ai.bat
```

它只设置环境变量并调用现有 `check.bat`：

```text
DISKPULSE_AI_CONFIGURE=1
```

`check.bat` 检测该模式后，不运行磁盘扫描，而是进入交互式配置流程。

### 5.2 配置操作

配置菜单提供：

1. 启用并配置 AI；
2. 修改现有配置；
3. 禁用 AI；
4. 删除本机 AI 配置；
5. 测试 API 连接；
6. 退出。

### 5.3 配置文件

路径：

```text
runtime/ai-config.local.json
```

建议结构：

```json
{
  "schemaVersion": 1,
  "enabled": true,
  "endpoint": "https://api.example.com/v1/chat/completions",
  "model": "model-name",
  "protectedApiKey": "DPAPI_ENCRYPTED_BASE64",
  "timeoutSeconds": 45,
  "updatedAt": "2026-07-14T10:00:00Z"
}
```

配置文件位于 `runtime/`，不进入 Git。

### 5.4 API Key 保护

使用 Windows DPAPI，作用域为当前 Windows 用户：

- 保存时：UTF-8 字节 → `ProtectedData.Protect()` → Base64；
- 使用时：Base64 → `ProtectedData.Unprotect()` → UTF-8 字符串；
- 不把明文 API Key 写入磁盘；
- 不把明文 API Key写入异常信息；
- 不将 Key 注入生成的 HTML。

DPAPI 只能防止配置文件被简单复制后直接读取，不应宣称它能抵抗已控制当前 Windows 用户会话的攻击者。

### 5.5 Endpoint 校验

允许：

```text
https://...
```

仅以下本地地址允许明文 HTTP：

```text
http://localhost:...
http://127.0.0.1:...
http://[::1]:...
```

拒绝其他远程 `http://` 地址。

远程接口必须有 API Key。本地兼容服务可以允许空 Key。

---

## 6. AI 调用条件

只有同时满足以下条件时才调用 AI：

1. 配置存在；
2. `enabled` 为 `true`；
3. endpoint 与 model 有效；
4. 至少有一个磁盘拥有可靠比较基线；
5. 至少存在一项状态为 `created`、`changed` 或 `removed` 的可靠变化；
6. 本次扫描不是全部失败。

以下情况跳过调用：

- AI 未启用；
- 配置缺失；
- 首次扫描，仅建立基线；
- 本次没有可靠变化；
- 全部磁盘扫描失败。

跳过不视为错误，应生成明确状态。

---

## 7. AI 输入数据设计

### 7.1 只使用现有可靠数据

输入来源：

- 当前磁盘容量结果；
- `directoryResults`；
- `historyCenter`；
- 扫描完整性；
- 目录解释率；
- 实际磁盘净变化；
- 未解释容量；
- 趋势分类。

不重新扫描目录，不增加深度，不读取文件内容。

### 7.2 数据范围

建议发送：

- 每块磁盘容量状态和实际净变化；
- 一级目录增长前 15 项；
- 一级目录释放前 10 项；
- 每个主要一级目录对应的二级目录明细，最多 5 项；
- 历史趋势最明显的前 10 项；
- 扫描状态、解释率和未解释容量；
- 未发送项的数量与合计变化量。

### 7.3 上下级目录去重

一级和二级目录存在包含关系，例如：

```text
C:\Program Files            +500 MB
C:\Program Files\Google     +420 MB
```

不能把两者相加为 920 MB。

输入必须明确区分：

```json
{
  "primaryChanges": [
    {
      "path": "C:\\Program Files",
      "deltaBytes": 524288000
    }
  ],
  "breakdown": [
    {
      "parentPath": "C:\\Program Files",
      "path": "C:\\Program Files\\Google",
      "deltaBytes": 440401920
    }
  ]
}
```

系统提示必须明确：

> `breakdown` 是 `primaryChanges` 的组成部分，不得再次累计到磁盘净变化中。

### 7.4 路径脱敏

至少处理：

```text
C:\Users\admin\... → %USERPROFILE%\...
```

替换时应使用当前 `$env:USERPROFILE` 的标准化路径进行不区分大小写匹配。

同时避免发送：

- Windows 用户名；
- API Key；
- DiskPulse 配置路径；
- 目录中的文件内容；
- 磁盘硬件序列号；
- 环境变量完整列表；
- HTTP 请求头。

### 7.5 建议数据结构

```json
{
  "schemaVersion": 1,
  "scanTime": "2026-07-14T10:30:00Z",
  "scanStatus": "complete",
  "drives": [
    {
      "drive": "C:",
      "capacityStatus": "good",
      "usedPercent": 62.1,
      "actualNetChangeBytes": 455081984,
      "locatedNetChangeBytes": 447741952,
      "unexplainedBytes": 7340032,
      "coverageRate": 96.4,
      "scanStatus": "complete"
    }
  ],
  "primaryGrowth": [],
  "primaryRelease": [],
  "breakdown": [],
  "historicalTrends": [],
  "omitted": {
    "growthCount": 0,
    "growthBytes": 0,
    "releaseCount": 0,
    "releaseBytes": 0
  }
}
```

---

## 8. Prompt 设计

### 8.1 System Prompt 职责

模型角色：

> 你是 DiskPulse 的磁盘变化解释助手。你只能根据提供的目录统计、变化量、趋势和扫描完整性进行分析。

必须要求模型：

- 用普通 Windows 用户能理解的中文；
- 优先说明本次主要增长与释放；
- 根据路径与趋势提出可能原因；
- 明确区分确认事实和推测；
- 不把上下级目录重复累计；
- 不建议手动删除系统目录或应用安装目录；
- 证据不足时明确说无法确定；
- 不声称读取了文件内容；
- 不声称联网核实了软件版本；
- 不生成 PowerShell 删除命令；
- 不夸大安全风险、硬盘健康或寿命问题。

### 8.2 输出格式

优先要求返回 JSON：

```json
{
  "summary": "本次发生了什么",
  "possibleCauses": [
    "可能原因"
  ],
  "confidence": "高|中等|低",
  "evidence": [
    "支持判断的证据"
  ],
  "recommendations": [
    "处理建议"
  ],
  "cautions": [
    "需要注意的证据边界"
  ]
}
```

不强制使用 API 的 `response_format` 参数，以兼容更多第三方 OpenAI-compatible 接口。

---

## 9. API 调用

### 9.1 调用方式

使用 PowerShell 自带：

```powershell
Invoke-RestMethod
```

标准请求：

```json
{
  "model": "用户配置模型",
  "messages": [
    {
      "role": "system",
      "content": "系统提示"
    },
    {
      "role": "user",
      "content": "脱敏后的结构化数据"
    }
  ],
  "temperature": 0.2
}
```

第一版不使用：

- 流式输出；
- 工具调用；
- function calling；
- 供应商专属字段；
- SDK。

### 9.2 PowerShell 5.1 兼容

实现必须：

- 不使用 PowerShell 7 专属语法；
- 请求正文显式按 UTF-8 发送；
- 必要时启用 TLS 1.2；
- 避免依赖 PowerShell 7 才有的参数；
- 在 Windows PowerShell 5.1 测试配置和请求构造。

### 9.3 响应读取

优先读取：

```text
choices[0].message.content
```

如果不存在，则报告“接口响应格式不兼容”。

---

## 10. 响应解析

处理顺序：

1. 读取返回文本；
2. 去除首尾空白；
3. 去除可选的 Markdown `json` 代码块；
4. 尝试 `ConvertFrom-Json`；
5. 校验预期字段；
6. 成功则按结构化数据保存；
7. 失败则保存为 `rawText`；
8. 空响应则标记为无效响应。

建议统一结果结构：

```json
{
  "scanId": "20260714-...",
  "status": "success",
  "generatedAt": "2026-07-14T10:31:00Z",
  "model": "model-name",
  "format": "structured",
  "analysis": {
    "summary": "...",
    "possibleCauses": [],
    "confidence": "中等",
    "evidence": [],
    "recommendations": [],
    "cautions": []
  },
  "error": null
}
```

纯文本兜底：

```json
{
  "status": "success",
  "format": "text",
  "rawText": "模型返回内容"
}
```

---

## 11. 错误分类

AI 错误必须转换为有限的用户可理解状态。

建议状态：

- `disabled`
- `not-configured`
- `baseline-required`
- `no-reliable-changes`
- `success`
- `timeout`
- `authentication-failed`
- `rate-limited`
- `connection-failed`
- `invalid-response`
- `configuration-error`
- `unknown-error`

建议映射：

- HTTP 401/403：API Key 或权限无效；
- HTTP 429：额度、频率或并发限制；
- 超时异常：请求超时；
- DNS/连接异常：无法连接接口；
- 内容为空或结构不兼容：响应无效；
- 其他错误：AI 分析失败，但报告仍正常生成。

错误对象不得包含：

- API Key；
- Authorization 头；
- 完整请求体；
- 可能含敏感信息的底层异常转储。

---

## 12. 结果保存

路径：

```text
runtime/last-ai-analysis.json
```

保存：

- scanId；
- 状态；
- 模型名；
- 时间；
- 结构化分析或纯文本；
- 安全化后的错误分类。

默认不保存：

- 明文 API Key；
- Authorization 头；
- 完整请求头；
- 原始未脱敏路径数据；
- API 提供商返回的完整调试对象。

该文件允许每次运行覆盖，因为它只用于最近一次分析和排查。

---

## 13. HTML 展示

### 13.1 注入方式

新增：

```text
INJECT_AI_ANALYSIS
```

PowerShell 在生成 HTML 前，将统一 AI 结果转换为 JSON 并注入。

必须保持单次正则占位符替换机制。

### 13.2 展示位置

建议放在“最新变化”区域之后、“历史比较中心”之前，标题：

```text
AI 变化解释
```

内容按以下结构展示：

- 本次发生了什么；
- 最可能的原因；
- 可信度；
- 证据；
- 建议怎么处理；
- 证据边界；
- 模型与生成时间。

### 13.3 状态展示

未成功时显示短状态，不制造空卡片：

- AI 分析未启用；
- 尚未配置 AI；
- 当前正在建立首次比较基线；
- 本次没有可靠变化，因此未调用 AI；
- AI 请求超时；
- API Key 或权限无效；
- 接口额度或频率受限；
- 无法连接 AI 接口；
- AI 返回格式无法识别。

### 13.4 前端安全

继续遵守现有约束：

- 使用 `element()`；
- 使用 `textContent`；
- 不使用 `innerHTML`；
- 不解析模型返回的 HTML；
- 不把模型文本当作可执行 Markdown；
- 长文本允许换行，但只作为纯文本显示。

---

## 14. 函数边界建议

后端建议增加以下小函数，避免把所有逻辑塞进主流程：

```text
Get-DiskPulseAIConfig
Protect-DiskPulseSecret
Unprotect-DiskPulseSecret
Test-DiskPulseAIEndpoint
Invoke-DiskPulseAIConfigure
ConvertTo-DiskPulseRedactedPath
New-DiskPulseAIInput
New-DiskPulseAIPrompt
Invoke-DiskPulseAIRequest
ConvertFrom-DiskPulseAIResponse
New-DiskPulseAIStatus
Write-DiskPulseAIResult
```

职责应保持单一：

- 配置函数不参与扫描；
- 脱敏函数不发网络请求；
- 输入构造函数只接收结构化数据；
- 请求函数只负责 HTTP；
- 响应函数只负责解析；
- HTML 只接收统一结果对象。

---

## 15. 测试设计

### 15.1 后端测试

至少覆盖：

- 用户目录路径脱敏；
- 路径大小写差异；
- 非用户目录不被错误替换；
- DPAPI 加密后不包含明文；
- DPAPI 可由当前用户正确解密；
- endpoint HTTPS 校验；
- 本地 HTTP 地址允许；
- 远程 HTTP 地址拒绝；
- 禁用时不构造请求；
- 未配置时不构造请求；
- 首次基线时跳过；
- 无可靠变化时跳过；
- 全部失败时跳过；
- Top N 截断；
- 省略项数量与字节合计；
- 一级、二级目录不重复累计；
- 正常 JSON 响应；
- Markdown JSON 代码块；
- 纯文本响应；
- 空响应；
- 401、429、超时、连接错误分类；
- 错误消息中不出现 API Key。

### 15.2 前端测试

至少覆盖：

- `INJECT_AI_ANALYSIS` 被替换；
- HTML 中不存在 API Key；
- AI 区域静态标记存在；
- 成功状态渲染；
- 跳过状态渲染；
- 错误状态渲染；
- 纯文本兜底渲染；
- 不使用 `innerHTML`；
- 模型内容只通过 `textContent` 显示；
- 提取后的 JavaScript 通过 `node --check`。

### 15.3 回归测试

修改 `check.bat` 后运行仓库现有全部测试：

```powershell
powershell.exe -NoProfile -File "tests\DiskPulse.Phase1.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase3.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase4.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase5.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Scanner.Tests.ps1"
```

AI 单元测试不得依赖真实网络，也不得消耗真实 API 额度。应通过模拟函数、测试模式或离线 fixture 验证。

---

## 16. 文档更新

README 必须明确说明：

- 默认仍为离线模式；
- AI 是可选功能；
- 启用后会连接用户指定的第三方模型接口；
- 会发送脱敏后的目录路径、变化量和趋势统计；
- 不发送文件内容；
- API Key 在当前 Windows 用户下使用 DPAPI 加密；
- AI 解释可能出错，不能替代目录数据本身；
- DiskPulse 不会根据 AI 建议自动删除文件。

`CLAUDE.md` 与 `AGENTS.md` 应补充：

- AI 配置和运行文件；
- AI 失败不得中断主报告；
- 不得把 API Key 写入仓库；
- 不得在测试中调用真实 API；
- PowerShell 5.1 兼容要求；
- 新占位符和测试命令。

---

## 17. 分阶段实施建议

### 阶段 1：配置与安全基础

- 新增 `configure-ai.bat`；
- 配置读取与保存；
- DPAPI 加密；
- endpoint 校验；
- 配置测试。

### 阶段 2：数据构造

- 路径脱敏；
- 一级目录主要变化；
- 二级目录 breakdown；
- Top N 与省略统计；
- 历史趋势整理；
- 输入 fixture 测试。

### 阶段 3：API 调用与解析

- 请求构造；
- 超时；
- 错误分类；
- JSON 与文本响应解析；
- 最近结果保存。

### 阶段 4：HTML 展示

- 注入统一 AI 状态；
- 成功、跳过、错误展示；
- 安全 DOM 渲染；
- 深色模式、响应式和打印样式检查。

### 阶段 5：回归与文档

- 全套测试；
- 真实扫描；
- 使用测试接口手动验证；
- README、CLAUDE、AGENTS 更新；
- 检查 Git diff 和敏感信息。

---

## 18. 验收标准

功能只有在满足以下条件时才算完成：

1. 未配置 AI 时，现有扫描和报告行为基本不变；
2. AI 配置默认关闭；
3. 配置后，有可靠变化时自动调用模型；
4. 首次扫描和无变化时不浪费请求；
5. 输入包含主要增长、释放、趋势、扫描完整性和未解释容量；
6. 一级、二级目录不会重复累计；
7. 用户目录自动脱敏；
8. 不读取或发送文件内容；
9. API Key 使用 DPAPI 加密；
10. API Key 不出现在 HTML、日志、快照或测试输出；
11. AI 失败不影响报告生成；
12. 结构化 JSON 与纯文本返回都能显示；
13. 不增加第三方运行依赖；
14. 保持 Windows PowerShell 5.1+ 兼容；
15. 所有现有测试通过；
16. 新增 AI 测试全部通过；
17. README 对联网行为和隐私范围说明清楚；
18. AI 只提供解释和建议，不执行清理操作。

---

## 19. 风险与控制

### 风险：第三方兼容接口格式不一致

控制：

- 第一版只支持常见 `choices[0].message.content`；
- 配置测试提前发现不兼容接口；
- 响应错误只影响 AI 区域。

### 风险：模型将推测写成事实

控制：

- 系统提示强制区分事实与推测；
- 页面显示“AI 解释”而非“系统结论”；
- 报告同时保留原始变化数据；
- 证据不足时要求输出低可信度。

### 风险：用户误删安装目录或系统目录

控制：

- Prompt 禁止直接建议手动删除系统或应用安装目录；
- 第一版不提供清理按钮；
- 不生成自动执行命令。

### 风险：API 成本或请求时间增加

控制：

- 仅有可靠变化时调用；
- Top N 限制；
- 固定超时；
- AI 可随时禁用；
- 不使用流式、多轮或工具调用。

### 风险：PowerShell 单文件继续增大

控制：

- 使用职责单一的小函数；
- AI 逻辑放在连续、清晰标记的区域；
- 不借此重构无关扫描代码；
- 保持实现范围单一。

---

## 20. 最终决策摘要

采用以下最终方案：

- AI 默认关闭；
- 用户通过 `configure-ai.bat` 配置；
- API Key 使用当前用户 DPAPI 加密；
- 兼容标准 OpenAI-compatible Chat Completions；
- 磁盘扫描完成后自动分析；
- 只发送脱敏后的目录统计、变化量和趋势；
- 不扩大扫描深度；
- 不读取文件内容；
- 不引入本地服务或第三方依赖；
- 模型结果直接注入本次 HTML；
- AI 请求失败不影响原报告；
- 第一版只解释，不执行任何清理操作。
