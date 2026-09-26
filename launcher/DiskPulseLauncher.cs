using System;
using System.Collections;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Resources;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            Payload.EnsureExtracted();
            DataPaths.EnsureMigrated(Payload.Root);
            Application.Run(new MainForm(Payload.Root));
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "DiskPulse", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}

internal static class Payload
{
    internal static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DiskPulse");

    internal static void EnsureExtracted()
    {
        EnsureExtracted(Root);
    }

    internal static void EnsureExtracted(string root)
    {
        Directory.CreateDirectory(root);
        string fullRoot = Path.GetFullPath(root);
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DiskPulse.Payload"))
        using (ResourceReader reader = new ResourceReader(stream))
        {
            foreach (DictionaryEntry entry in reader)
            {
                string key = (string)entry.Key;
                string path = Path.Combine(root, key);
                string fullPath = Path.GetFullPath(path);
                if (!fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException("Unsafe payload path: " + key);
                }

                string parent = Path.GetDirectoryName(path);
                if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);

                byte[] data = (byte[])entry.Value;
                if (File.Exists(path) && HashesEqual(File.ReadAllBytes(path), data))
                {
                    continue;
                }

                string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    File.WriteAllBytes(temp, data);
                    if (File.Exists(path))
                    {
                        File.Replace(temp, path, null);
                    }
                    else
                    {
                        File.Move(temp, path);
                    }
                }
                finally
                {
                    if (File.Exists(temp)) File.Delete(temp);
                }
            }
        }
    }

    private static bool HashesEqual(byte[] first, byte[] second)
    {
        using (SHA256 sha = SHA256.Create())
        {
            byte[] firstHash = sha.ComputeHash(first);
            byte[] secondHash = sha.ComputeHash(second);
            if (firstHash.Length != secondHash.Length) return false;
            for (int i = 0; i < firstHash.Length; i++)
            {
                if (firstHash[i] != secondHash[i]) return false;
            }
            return true;
        }
    }
}

internal static class DataPaths
{
    internal static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DiskPulse", "data");

    internal static string Runtime { get { return Path.Combine(Root, "runtime"); } }

    internal static void EnsureMigrated(string appRoot)
    {
        string diagnostics = RunMigration(appRoot, Root, new [] {
            Path.Combine(appRoot, "runtime"), Path.Combine(appRoot, "app", "runtime"),
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "runtime") });
        if (!String.IsNullOrWhiteSpace(diagnostics))
            MessageBox.Show(diagnostics, "DiskPulse migration", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    internal static string RunMigration(string appRoot, string dataRoot, string[] sources)
    {
        // Keep JSON validation and lock/atomic-write semantics in the canonical runtime.
        //
        // The context is passed as `$env:` assignments inside the command text instead of via
        // ProcessStartInfo.EnvironmentVariables. That property is a case-insensitive
        // StringDictionary backed by the current environment, so a host whose environment block
        // carries the same variable in two casings (both "Path" and "PATH" do occur in practice)
        // makes the copy throw ArgumentException before the child process can even start. The
        // canonical runtime launches its AI worker through exactly this command-text pattern.
        string command = String.Join("; ", new []
        {
            "$ErrorActionPreference='Stop'",
            "[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false",
            Env("DISKPULSE_ROOT", appRoot),
            Env("DISKPULSE_DATA_ROOT", dataRoot),
            Env("DISKPULSE_SCRIPT_PATH", Path.Combine(appRoot, "check.bat")),
            "$env:DISKPULSE_MIGRATE='1'",
            Env("DISKPULSE_MIGRATION_SOURCES", String.Join("\n", sources)),
            "try { Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8 | Invoke-Expression } catch { Write-Output 'DiskPulse migration state unavailable; existing data preserved.'; exit 1 }"
        });
        ProcessStartInfo info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" + command + "\"",
            WorkingDirectory = appRoot, UseShellExecute = false, CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardOutput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
        using (Process process = Process.Start(info))
        {
            string diagnostics = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            if (process.ExitCode != 0 && String.IsNullOrWhiteSpace(diagnostics)) return "Migration state unavailable; existing data preserved.";
            return diagnostics;
        }
    }

    // PowerShell single-quoted literal: only an embedded apostrophe needs doubling.
    private static string Env(string name, string value)
    {
        return "$env:" + name + "='" + value.Replace("'", "''") + "'";
    }
}

// Reader for the flat scan-progress state file published by check.bat (see
// src/powershell/Progress.ps1). The payload is generated by DiskPulse itself: a single
// flat JSON object with ASCII keys, numeric values and short enum strings, so a strict
// key extraction is sufficient and keeps the launcher free of any parser dependency.
// A missing, unreadable or malformed file yields null and the launcher degrades to the
// original "scanning" message without progress details.
internal sealed class ScanProgressSnapshot
{
    internal const int StaleAfterSeconds = 20;

    internal string ScanId = "";
    internal string Status = "";
    internal string Stage = "";
    internal string Drive = "";
    internal DateTime UpdatedAtUtc = DateTime.MinValue;
    internal double Percent;
    internal bool PercentKnown;
    internal int CompletedDrives;
    internal int TotalDrives;
    internal long FilesProcessed;
    internal long DirectoriesProcessed;
    internal long ElapsedMilliseconds;
    internal bool IsValid;

    internal bool IsRunning { get { return Status == "running"; } }

    internal bool IsStaleUtc(DateTime nowUtc)
    {
        if (UpdatedAtUtc == DateTime.MinValue) return true;
        return (nowUtc - UpdatedAtUtc).TotalSeconds > StaleAfterSeconds;
    }
}

internal static class ScanProgressFile
{
    internal const string FileName = "scan-progress.json";

    private static string ExtractString(string json, string key)
    {
        Match match = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
        if (!match.Success) return null;
        return UnescapeJson(match.Groups[1].Value);
    }

    private static string ExtractRaw(string json, string key)
    {
        Match match = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?|true|false|null)");
        return match.Success ? match.Groups[1].Value : null;
    }

    private static string UnescapeJson(string value)
    {
        if (value.IndexOf('\\') < 0) return value;
        StringBuilder builder = new StringBuilder(value.Length);
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c != '\\' || i + 1 >= value.Length)
            {
                builder.Append(c);
                continue;
            }
            i++;
            char escaped = value[i];
            if (escaped == 'n') builder.Append('\n');
            else if (escaped == 't') builder.Append('\t');
            else if (escaped == 'r') builder.Append('\r');
            else if (escaped == 'u' && i + 4 < value.Length)
            {
                int code;
                if (int.TryParse(value.Substring(i + 1, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code))
                {
                    builder.Append((char)code);
                    i += 4;
                }
            }
            else builder.Append(escaped);
        }
        return builder.ToString();
    }

    private static long ToLong(string raw)
    {
        long value;
        return long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out value) ? value : 0;
    }

    private static int ToInt(string raw)
    {
        int value;
        return int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out value) ? value : 0;
    }

    internal static ScanProgressSnapshot Read(string path)
    {
        string json;
        try
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
            {
                json = reader.ReadToEnd();
            }
        }
        catch (Exception ex)
        {
            if (ex is IOException || ex is UnauthorizedAccessException || ex is ArgumentException
                || ex is NotSupportedException || ex is System.Security.SecurityException) return null;
            throw;
        }
        if (String.IsNullOrWhiteSpace(json) || !json.TrimStart().StartsWith("{", StringComparison.Ordinal)) return null;

        string status = ExtractString(json, "status");
        string scanId = ExtractString(json, "scanId");
        string updatedAt = ExtractString(json, "updatedAt");
        if (status == null || scanId == null || updatedAt == null) return null;
        if (status != "running" && status != "complete" && status != "failed") return null;

        ScanProgressSnapshot snapshot = new ScanProgressSnapshot();
        snapshot.ScanId = scanId;
        snapshot.Status = status;
        snapshot.Stage = ExtractString(json, "stage") ?? "";
        snapshot.Drive = ExtractString(json, "drive") ?? "";
        snapshot.Percent = ExtractRaw(json, "percent") == null ? -1 : ToDoubleSafe(ExtractRaw(json, "percent"));
        snapshot.PercentKnown = ExtractRaw(json, "percentKnown") == "true" && snapshot.Percent >= 0;
        snapshot.CompletedDrives = ToInt(ExtractRaw(json, "completedDrives"));
        snapshot.TotalDrives = ToInt(ExtractRaw(json, "totalDrives"));
        snapshot.FilesProcessed = ToLong(ExtractRaw(json, "filesProcessed"));
        snapshot.DirectoriesProcessed = ToLong(ExtractRaw(json, "directoriesProcessed"));
        snapshot.ElapsedMilliseconds = ToLong(ExtractRaw(json, "elapsedMilliseconds"));
        DateTime parsed;
        if (DateTime.TryParse(updatedAt, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out parsed))
        {
            snapshot.UpdatedAtUtc = parsed.ToUniversalTime();
        }
        snapshot.IsValid = true;
        return snapshot;
    }

    private static double ToDoubleSafe(string raw)
    {
        double value;
        return double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out value) ? value : -1;
    }
}

internal sealed class MainForm : Form
{
    private static readonly Color AccentColor = Color.FromArgb(0x33, 0x70, 0xFF);
    private static readonly Color AccentHoverColor = Color.FromArgb(0x4B, 0x83, 0xF5);
    private static readonly Color TextColor = Color.FromArgb(0x11, 0x18, 0x27);
    private static readonly Color MutedColor = Color.FromArgb(0x66, 0x70, 0x85);
    private static readonly Color PanelBgColor = Color.FromArgb(0xF5, 0xF7, 0xFB);
    private static readonly Color LineColor = Color.FromArgb(0xE4, 0xE9, 0xF1);
    private static readonly Color GoodColor = Color.FromArgb(0x07, 0x96, 0x69);
    private static readonly Color DangerColor = Color.FromArgb(0xDC, 0x26, 0x26);

    private readonly string root;
    private readonly string progressFilePath;
    private readonly Button scanButton;
    private readonly Button openDashboardButton;
    private readonly Label statusLabel;
    private readonly Label stageLabel;
    private readonly Label percentLabel;
    private readonly Label countsLabel;
    private readonly Label elapsedLabel;
    private readonly ProgressBar progressBar;
    private readonly System.Windows.Forms.Timer progressTimer;
    private readonly Stopwatch scanStopwatch = new Stopwatch();
    // Only the progress bar is scan-exclusive: every other line is an auto-size label that
    // simply stays empty in the idle state, so completion and failure text remain visible.
    private readonly Control[] progressOnlyControls;
    private string lastStageKey = "";
    private string lastStageDrive = "";
    private bool scanning;
    private bool adopting;

    internal MainForm(string applicationRoot)
    {
        root = applicationRoot;
        progressFilePath = Path.Combine(DataPaths.Runtime, ScanProgressFile.FileName);

        Text = "DiskPulse";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 9.5F);
        BackColor = Color.White;
        ForeColor = TextColor;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96F, 96F);
        ClientSize = new Size(444, 452);
        MinimumSize = new Size(444, 452);

        TableLayoutPanel layout = new TableLayoutPanel();
        layout.Dock = DockStyle.Fill;
        layout.ColumnCount = 1;
        layout.RowCount = 4;
        layout.Padding = new Padding(24, 22, 24, 18);
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        Controls.Add(layout);

        // --- Header: product name + shared tagline (mirrors the dashboard wording). ---
        TableLayoutPanel header = new TableLayoutPanel();
        header.Dock = DockStyle.Top;
        header.AutoSize = true;
        header.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        header.ColumnCount = 1;
        header.RowCount = 2;
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        header.Margin = new Padding(0, 0, 0, 14);
        Label title = new Label { Text = "DiskPulse", AutoSize = true, Font = new Font("Segoe UI", 17.5F, FontStyle.Bold), ForeColor = TextColor, Margin = new Padding(0) };
        Label subtitle = new Label { Text = "磁盘容量与目录变化看板", AutoSize = true, ForeColor = MutedColor, Margin = new Padding(1, 4, 0, 0) };
        header.Controls.Add(title, 0, 0);
        header.Controls.Add(subtitle, 0, 1);
        layout.Controls.Add(header, 0, 0);

        // --- Primary action: the only visually dominant button. ---
        scanButton = new Button();
        scanButton.Text = "扫描磁盘";
        scanButton.Height = 44;
        scanButton.Dock = DockStyle.Fill;
        scanButton.FlatStyle = FlatStyle.Flat;
        scanButton.FlatAppearance.BorderSize = 0;
        scanButton.FlatAppearance.MouseOverBackColor = AccentHoverColor;
        scanButton.BackColor = AccentColor;
        scanButton.ForeColor = Color.White;
        scanButton.Font = new Font("Segoe UI", 10.5F, FontStyle.Bold);
        scanButton.Cursor = Cursors.Hand;
        scanButton.Margin = new Padding(0, 0, 0, 16);
        scanButton.Click += Scan;
        layout.Controls.Add(scanButton, 0, 1);

        // --- Status surface: shared visual language with the dashboard track color. ---
        Panel statusPanel = new Panel();
        statusPanel.Dock = DockStyle.Fill;
        statusPanel.BackColor = PanelBgColor;
        statusPanel.Padding = new Padding(16, 14, 16, 14);
        statusPanel.Margin = new Padding(0, 0, 0, 16);
        TableLayoutPanel statusLayout = new TableLayoutPanel();
        statusLayout.Dock = DockStyle.Top;
        statusLayout.AutoSize = true;
        statusLayout.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        statusLayout.ColumnCount = 1;
        statusLayout.RowCount = 6;
        statusLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        Label stateCaption = new Label { Text = "状态", AutoSize = true, ForeColor = MutedColor, Font = new Font("Segoe UI", 8.5F), Margin = new Padding(1, 0, 0, 4) };
        statusLabel = new Label { Text = "准备就绪", AutoSize = true, ForeColor = TextColor, Font = new Font("Segoe UI", 12.5F, FontStyle.Bold), Margin = new Padding(1, 0, 0, 8) };

        TableLayoutPanel stageRow = new TableLayoutPanel();
        stageRow.Dock = DockStyle.Fill;
        stageRow.AutoSize = true;
        stageRow.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        stageRow.ColumnCount = 2;
        stageRow.RowCount = 1;
        stageRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        stageRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        stageRow.Margin = new Padding(0, 0, 0, 8);
        stageLabel = new Label { Text = "", AutoSize = true, ForeColor = MutedColor, Margin = new Padding(1, 0, 0, 0) };
        percentLabel = new Label { Text = "", AutoSize = true, ForeColor = TextColor, Font = new Font("Segoe UI", 9.5F, FontStyle.Bold), Margin = new Padding(0, 0, 1, 0) };
        stageRow.Controls.Add(stageLabel, 0, 0);
        stageRow.Controls.Add(percentLabel, 1, 0);

        progressBar = new ProgressBar();
        progressBar.Height = 10;
        progressBar.Dock = DockStyle.Fill;
        progressBar.Margin = new Padding(0, 0, 0, 10);

        countsLabel = new Label { Text = "", AutoSize = true, ForeColor = TextColor, Margin = new Padding(1, 0, 0, 6) };
        elapsedLabel = new Label { Text = "", AutoSize = true, ForeColor = MutedColor, Margin = new Padding(1, 0, 0, 0) };
        statusLayout.Controls.Add(stateCaption, 0, 0);
        statusLayout.Controls.Add(statusLabel, 0, 1);
        statusLayout.Controls.Add(stageRow, 0, 2);
        statusLayout.Controls.Add(progressBar, 0, 3);
        statusLayout.Controls.Add(countsLabel, 0, 4);
        statusLayout.Controls.Add(elapsedLabel, 0, 5);
        statusPanel.Controls.Add(statusLayout);
        layout.Controls.Add(statusPanel, 0, 2);
        progressOnlyControls = new Control[] { progressBar };
        progressBar.Visible = false;

        // --- Footer: secondary (打开看板), utility (AI 设置), quiet exit. ---
        TableLayoutPanel footer = new TableLayoutPanel();
        footer.Dock = DockStyle.Fill;
        footer.AutoSize = true;
        footer.ColumnCount = 3;
        footer.RowCount = 1;
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.Margin = new Padding(0);
        openDashboardButton = MakeSecondaryButton("打开看板", OpenDashboard);
        Button aiButton = MakeSecondaryButton("AI 设置", OpenAiSettings);
        Button exitButton = new Button();
        exitButton.Text = "退出";
        exitButton.AutoSize = true;
        exitButton.FlatStyle = FlatStyle.Flat;
        exitButton.FlatAppearance.BorderSize = 0;
        exitButton.BackColor = Color.White;
        exitButton.ForeColor = MutedColor;
        exitButton.Margin = new Padding(10, 0, 0, 0);
        exitButton.Anchor = AnchorStyles.Right;
        exitButton.Click += delegate { Close(); };
        footer.Controls.Add(openDashboardButton, 0, 0);
        footer.Controls.Add(aiButton, 1, 0);
        footer.Controls.Add(exitButton, 2, 0);
        layout.Controls.Add(footer, 0, 3);

        progressTimer = new System.Windows.Forms.Timer();
        progressTimer.Interval = 500;
        progressTimer.Tick += ProgressTimerTick;

        Load += delegate { AdoptRunningScan(); };
        FormClosing += OnFormClosing;
    }

    private Button MakeSecondaryButton(string text, EventHandler handler)
    {
        Button button = new Button();
        button.Text = text;
        button.AutoSize = true;
        button.MinimumSize = new Size(0, 38);
        button.Padding = new Padding(10, 0, 10, 0);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderColor = LineColor;
        button.FlatAppearance.MouseOverBackColor = PanelBgColor;
        button.BackColor = Color.White;
        button.ForeColor = TextColor;
        button.Cursor = Cursors.Hand;
        button.Margin = new Padding(0, 0, 10, 0);
        button.Click += handler;
        return button;
    }

    private void Scan(object sender, EventArgs args)
    {
        if (scanning || adopting) return;
        scanning = true;
        scanButton.Enabled = false;
        scanStopwatch.Reset();
        scanStopwatch.Start();
        ShowScanning(null, false);
        try
        {
            Process process = Start("wscript.exe", Quote(Path.Combine(root, "DiskPulse.vbs")), true, true);
            Thread thread = new Thread(new ThreadStart(delegate
            {
                process.WaitForExit();
                int exitCode = process.ExitCode;
                if (!IsDisposed && IsHandleCreated)
                {
                    BeginInvoke((Action)delegate { ScanFinished(exitCode); });
                }
            }));
            thread.IsBackground = true;
            thread.Start();
            progressTimer.Start();
        }
        catch (Exception ex)
        {
            progressTimer.Stop();
            ScanFinished(-1, ex.Message);
        }
    }

    private void ScanFinished(int exitCode, string error = null)
    {
        progressTimer.Stop();
        scanning = false;
        adopting = false;
        scanStopwatch.Stop();
        scanButton.Enabled = true;
        if (exitCode == 0)
        {
            ShowCompleted();
            OpenDashboard(null, EventArgs.Empty);
            return;
        }

        string stageText = DescribeStageBrief(lastStageKey, lastStageDrive);
        string message = String.IsNullOrEmpty(error)
            ? "扫描未成功完成" + (stageText == null ? "" : "（阶段：" + stageText + "）") + "。"
            : "无法启动扫描：" + error;
        ShowFailed(stageText);
        string log = Path.Combine(DataPaths.Runtime, "last-run.log");
        if (File.Exists(log)) message += Environment.NewLine + Environment.NewLine + "日志：" + log;
        MessageBox.Show(message, "DiskPulse", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private void ProgressTimerTick(object sender, EventArgs args)
    {
        ScanProgressSnapshot snapshot = ScanProgressFile.Read(progressFilePath);
        if (snapshot == null || !snapshot.IsValid)
        {
            // Missing or unreadable state file: degrade to the original status text.
            if (scanning || adopting) ShowScanning(null, false);
            return;
        }
        if (snapshot.IsRunning)
        {
            bool stale = snapshot.IsStaleUtc(DateTime.UtcNow);
            lastStageKey = snapshot.Stage;
            lastStageDrive = snapshot.Drive;
            ShowScanning(snapshot, stale);
            return;
        }
        // A terminal state file is only actionable for an adopted scan; for our own scan
        // the child process exit code remains authoritative.
        if (adopting)
        {
            progressTimer.Stop();
            adopting = false;
            scanButton.Enabled = true;
            if (snapshot.Status == "complete") ShowCompleted();
            else ShowFailed(null);
        }
    }

    private void AdoptRunningScan()
    {
        ScanProgressSnapshot snapshot = ScanProgressFile.Read(progressFilePath);
        if (snapshot == null || !snapshot.IsValid || !snapshot.IsRunning || snapshot.IsStaleUtc(DateTime.UtcNow)) return;
        adopting = true;
        scanButton.Enabled = false;
        lastStageKey = snapshot.Stage;
        lastStageDrive = snapshot.Drive;
        ShowScanning(snapshot, false);
        progressTimer.Start();
    }

    private void ShowScanning(ScanProgressSnapshot snapshot, bool stale)
    {
        bool percentKnown = snapshot != null && snapshot.PercentKnown && !stale;
        statusLabel.Text = "正在扫描磁盘";
        statusLabel.ForeColor = TextColor;
        stageLabel.Text = snapshot == null ? "正在准备扫描…" : DescribeStage(snapshot, stale);
        percentLabel.Text = snapshot == null ? "" : percentKnown ? "约 " + Math.Round(snapshot.Percent).ToString(CultureInfo.InvariantCulture) + "%" : stale ? "进度未知" : "";
        if (percentKnown)
        {
            progressBar.Style = ProgressBarStyle.Blocks;
            progressBar.Value = (int)Math.Max(0, Math.Min(100, Math.Round(snapshot.Percent)));
        }
        else
        {
            progressBar.Style = ProgressBarStyle.Marquee;
            progressBar.MarqueeAnimationSpeed = 30;
        }
        countsLabel.Text = snapshot == null ? "" : String.Format(
            CultureInfo.InvariantCulture, "{0:N0} 个文件 · {1:N0} 个目录",
            snapshot.FilesProcessed, snapshot.DirectoriesProcessed);
        long elapsed = snapshot != null && !stale && snapshot.ElapsedMilliseconds > 0
            ? snapshot.ElapsedMilliseconds
            : scanStopwatch.ElapsedMilliseconds;
        elapsedLabel.Text = elapsed <= 0 ? "" : "已用 " + FormatElapsed(elapsed);
        SetProgressVisible(true);
    }

    private string DescribeStage(ScanProgressSnapshot snapshot, bool stale)
    {
        if (snapshot.Stage == "scan")
        {
            string driveText = String.IsNullOrEmpty(snapshot.Drive) ? "" : " " + snapshot.Drive;
            string position = "";
            if (snapshot.TotalDrives > 1)
            {
                int current = Math.Min(snapshot.CompletedDrives + 1, snapshot.TotalDrives);
                position = "（第 " + current.ToString(CultureInfo.InvariantCulture) + "/"
                    + snapshot.TotalDrives.ToString(CultureInfo.InvariantCulture) + " 块）";
            }
            string baseText = "正在扫描" + driveText + position;
            return stale ? baseText + " · 进度暂不可用" : baseText;
        }
        if (snapshot.Stage == "report") return "正在生成报告";
        if (snapshot.Stage == "init") return "正在准备";
        return stale ? "仍在扫描，进度暂不可用" : "正在扫描…";
    }

    private static string DescribeStageBrief(string stage, string drive)
    {
        if (stage == "scan") return String.IsNullOrEmpty(drive) ? "扫描磁盘" : "扫描磁盘 " + drive;
        if (stage == "report") return "生成报告";
        if (stage == "init") return "初始化";
        return null;
    }

    private static string FormatElapsed(long milliseconds)
    {
        long totalSeconds = Math.Max(0, milliseconds / 1000);
        long hours = totalSeconds / 3600;
        long minutes = (totalSeconds % 3600) / 60;
        long seconds = totalSeconds % 60;
        if (hours > 0) return String.Format(CultureInfo.InvariantCulture, "{0} 小时 {1} 分 {2} 秒", hours, minutes, seconds);
        if (minutes > 0) return String.Format(CultureInfo.InvariantCulture, "{0} 分 {1} 秒", minutes, seconds);
        return String.Format(CultureInfo.InvariantCulture, "{0} 秒", seconds);
    }

    private void ShowCompleted()
    {
        statusLabel.Text = "扫描完成";
        statusLabel.ForeColor = GoodColor;
        stageLabel.Text = "完成于 " + DateTime.Now.ToString("HH:mm", CultureInfo.InvariantCulture);
        percentLabel.Text = "";
        countsLabel.Text = "";
        elapsedLabel.Text = "";
        SetProgressVisible(false);
    }

    private void ShowFailed(string stageText)
    {
        statusLabel.Text = "扫描失败";
        statusLabel.ForeColor = DangerColor;
        stageLabel.Text = stageText == null ? "扫描未成功完成。" : "阶段：" + stageText;
        percentLabel.Text = "";
        countsLabel.Text = "";
        elapsedLabel.Text = "";
        SetProgressVisible(false);
    }

    private void SetProgressVisible(bool visible)
    {
        foreach (Control control in progressOnlyControls)
        {
            control.Visible = visible;
        }
    }

    private void OpenDashboard(object sender, EventArgs args)
    {
        string dashboard = Path.Combine(DataPaths.Runtime, "DiskPulse.html");
        if (!File.Exists(dashboard))
        {
            MessageBox.Show("还没有看板，请先扫描磁盘。", "DiskPulse", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo { FileName = dashboard, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show("无法打开看板：" + ex.Message + Environment.NewLine + Environment.NewLine
                + "文件位置：" + dashboard, "DiskPulse", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (statusLabel.Text == "扫描完成")
        {
            // Keep the completion state (status colour + finish time) intact; only the
            // secondary line changes to confirm the dashboard was opened.
            countsLabel.Text = "看板已打开。";
        }
        else
        {
            statusLabel.Text = "看板已打开";
            statusLabel.ForeColor = TextColor;
        }
    }

    private void OnFormClosing(object sender, FormClosingEventArgs args)
    {
        if (!scanning && !adopting) return;
        DialogResult choice = MessageBox.Show(
            "扫描仍在后台进行。" + Environment.NewLine + Environment.NewLine
            + "关闭此窗口不会中断扫描，稍后重新打开 DiskPulse 仍可看到进度和结果。"
            + Environment.NewLine + Environment.NewLine + "仍要关闭吗？",
            "DiskPulse", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
        if (choice != DialogResult.Yes) args.Cancel = true;
    }

    private void OpenAiSettings(object sender, EventArgs args)
    {
        Start("cmd.exe", "/c " + Quote(Path.Combine(root, "configure-ai.bat")), false);
    }

    private static Process Start(string fileName, string arguments, bool hidden, bool noOpen = false)
    {
        ProcessStartInfo info = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = Payload.Root,
            UseShellExecute = false,
            CreateNoWindow = hidden,
            WindowStyle = hidden ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal
        };
        if (noOpen)
        {
            // Best effort: the launcher shows its own failure state and opens the dashboard
            // itself, so these flags only suppress duplicate browser/dialog output. The
            // environment dictionary can reject an assignment on hosts that expose the same
            // variable in two casings (see RunMigration), and a scan must never be aborted by it.
            TrySetEnvironmentVariable(info, "DISKPULSE_NO_OPEN", "1");
            TrySetEnvironmentVariable(info, "DISKPULSE_NO_ERROR_DIALOG", "1");
        }
        return Process.Start(info);
    }

    private static void TrySetEnvironmentVariable(ProcessStartInfo info, string name, string value)
    {
        try
        {
            info.EnvironmentVariables[name] = value;
        }
        catch (ArgumentException) { }
        catch (NotSupportedException) { }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
