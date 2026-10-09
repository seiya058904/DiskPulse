# DiskPulse

**Know where disk space went — and what changed since last time.**

面向 Windows 的离线磁盘容量、趋势与目录变化看板。扫描、建立基线、比较增减，最后生成可以直接在浏览器打开的本地报告。

**[⬇️ Get DiskPulse](https://github.com/seiya058904/DiskPulse/releases/latest)** · [Run a scan](#quick-start) · [Optional AI](#optional-ai-explanation-off-by-default) · [Privacy](#privacy-and-trust) · [Source guide](AGENTS.md)

<img width="760" alt="DiskPulse project artwork" src="https://github.com/user-attachments/assets/4b06b439-eb31-4c4f-9e0e-f17e7529a342" />


## 📊 What the report tells you

> **Two questions, one report:** How much space is left? What actually grew or shrank since the previous scan?

| View | What it tells you |
| --- | --- |
| 💽 **Disk overview** | 本机固定磁盘容量、使用比例及趋势 |
| 📈 **History** | 每次扫描后对比历史容量，给出基于有效数据的空间变化与预测 |
| 📁 **Directory changes** | 比较根目录、一级与二级目录的增长和释放 |
| 🧭 **Scan quality** | 展示无法访问的区域、排除项目、解释率和扫描完整性 |
| 🧠 **Optional AI explanation** | 主动开启后可发送脱敏摘要解释变化；不启用也可手动复制分析数据 |

首次扫描建立基线；后续扫描才可能得到可信的增减对比。**不同卷即使复用了盘符，也不会被错误地当作同一磁盘历史。**

## Quick start

1. 从 [GitHub Releases](https://github.com/seiya058904/DiskPulse/releases/latest) 获取 `DiskPulse-Setup-*.exe`（预审计时记录的版本为 [v1.5.1](https://github.com/seiya058904/DiskPulse/releases/tag/v1.5.1)）。
2. 安装后启动 **DiskPulse**，点击 **扫描磁盘**。
3. 等待浏览器打开本地 HTML 看板。首次扫描建立基线；从第二次扫描开始查看目录增减与趋势。

开发仓库中也保留了几种运行入口：

| Entry | Purpose |
| --- | --- |
| `DiskPulse.vbs` | 普通运行，无终端窗口（推荐） |
| `check.bat` | 显示进度的调试扫描 |
| `check-profile.bat` | 性能诊断，生成 profile 记录 |
| `configure-ai.bat` | 可选 AI 配置与关闭 |

**Requirements:** Windows + Windows PowerShell 5.1 or newer. Normal use needs neither Node.js nor Python. History and reports live under `%LOCALAPPDATA%\DiskPulse\data\runtime`; ordinary upgrades and uninstall do not silently erase them.

## Optional AI explanation (off by default)

DiskPulse 的磁盘扫描和 HTML 报告**完全离线**。仅在用户主动启用、配置 API 后，才尝试向所选服务发送脱敏的容量和目录变化摘要。也可完全不提供 API Key，使用报告中的 **“复制给 AI”** 功能进行手动解释。

```text
扫描本地卷 → 保存可信基线 → 比较目录变化 → 生成 HTML 报告
                                         └─→ 可选：脱敏摘要 → AI 解释
```

运行 `configure-ai.bat` 可配置兼容 Chat Completions 的提供方或自定义接口，关闭或删除本地 AI 配置。API Key 在当前 Windows 用户范围使用 DPAPI 加密存储。AI 结果是辅助性解释，不应替代原始扫描事实；接口失败不影响磁盘报告。

## Privacy and trust

- **不会读取文件内容**，只聚合允许的磁盘/目录容量信息；不跟踪单个文件，也不会自动删除文件。
- 跳过 Reparse Point、Junction、符号链接及明确排除的系统目录。扫描不完整时不会覆盖最近的完整基线。
- 本地报告可能显示真实本机路径；发送给 AI 的路径经过用户目录脱敏。
- 不发送 API Key、磁盘硬件标识或完整用户目录路径。卷 GUID 仅用于本地历史可靠性判断。
- 只有身份确认且基线可比较的卷才形成有效趋势；未知变化保持未知，而非伪装为 `0`。

## Development / verification

`src/` 是权威源代码；`check.bat` 是生成工件。**不要直接编辑生成文件中的程序逻辑。**

```powershell
# 源码更改后重新生成运行文件
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-check.ps1

# 标准验证；无 NSIS 时跳过安装器验证
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1

# 包括 NSIS 安装器的完整验证
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1 -IncludeInstaller
```

打包脚本为 [`build-installer.ps1`](build-installer.ps1)，安装器来源在 [`installer/`](installer/)；测试、源代码和变更边界详见 [`AGENTS.md`](AGENTS.md)、[`PRODUCT.md`](PRODUCT.md) 和 [`DESIGN.md`](DESIGN.md)。

版本更新、签名和正式 Release 是独立的发布流程；文档或功能提交不等于发布新安装包。
