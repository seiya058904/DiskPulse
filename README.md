# DiskPulse

<img width="1672" height="941" alt="project-diskpulse" src="https://github.com/user-attachments/assets/4b06b439-eb31-4c4f-9e0e-f17e7529a342" />

DiskPulse 是一个零依赖、离线运行的 Windows 磁盘容量与目录变化看板。

双击 `check.bat` 后，程序会读取本地固定磁盘容量，保存历史记录，并在脚本旁的 `runtime/` 中生成自包含 HTML 报告。报告保留容量总览、使用率状态、趋势和满盘预测，并在建立基线后定位一级、二级目录的增长与释放。

## 使用方法

双击 `check.bat`。首次运行建立每个磁盘的目录基线；后续运行显示目录变化、解释率、扫描完整性、预期排除和无法访问路径。

运行数据只保存在 `runtime/`，不会联网。程序不会读取文件内容，也不会追踪单个文件或自动删除用户文件。

## 环境

- Windows
- Windows PowerShell 5.1 或更高版本
- 无需安装 Node.js、Python 或其他依赖

## 扫描边界

目录扫描只聚合根目录文件、一级目录和二级目录。Reparse Point、Junction、符号链接、`System Volume Information` 与 `$RECYCLE.BIN` 会被排除。无法访问的范围会在报告中标记，部分扫描不会覆盖该磁盘最近的完整基线。
