using System;
using System.Collections;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Resources;
using System.Security.Cryptography;
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
        ProcessStartInfo info = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$ErrorActionPreference='Stop'; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false; try { Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8 | Invoke-Expression } catch { Write-Output 'DiskPulse migration state unavailable; existing data preserved.'; exit 1 }\"",
            WorkingDirectory = appRoot, UseShellExecute = false, CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardOutput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
        info.EnvironmentVariables["DISKPULSE_ROOT"] = appRoot;
        info.EnvironmentVariables["DISKPULSE_DATA_ROOT"] = dataRoot;
        info.EnvironmentVariables["DISKPULSE_SCRIPT_PATH"] = Path.Combine(appRoot, "check.bat");
        info.EnvironmentVariables["DISKPULSE_MIGRATE"] = "1";
        info.EnvironmentVariables["DISKPULSE_MIGRATION_SOURCES"] = String.Join("\n", sources);
        using (Process process = Process.Start(info))
        {
            string diagnostics = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            if (process.ExitCode != 0 && String.IsNullOrWhiteSpace(diagnostics)) return "Migration state unavailable; existing data preserved.";
            return diagnostics;
        }
    }
}

internal sealed class MainForm : Form
{
    private readonly string root;
    private readonly Button scanButton;
    private readonly Label statusLabel;
    private bool scanning;

    internal MainForm(string applicationRoot)
    {
        root = applicationRoot;
        Text = "DiskPulse";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(390, 245);
        MinimumSize = new Size(390, 245);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;

        Label title = new Label { Text = "DiskPulse", AutoSize = true, Font = new Font("Segoe UI", 18, FontStyle.Bold), Location = new Point(28, 24) };
        Label description = new Label { Text = "磁盘容量与目录变化看板", AutoSize = true, Location = new Point(30, 64) };
        scanButton = MakeButton("扫描磁盘", new Point(28, 98), Scan);
        MakeButton("打开看板", new Point(190, 98), OpenDashboard);
        MakeButton("AI 设置", new Point(28, 145), OpenAiSettings);
        MakeButton("退出", new Point(190, 145), delegate { Close(); });
        statusLabel = new Label { Text = "准备就绪", AutoSize = true, ForeColor = Color.DimGray, Location = new Point(30, 202) };

        Controls.AddRange(new Control[] { title, description, scanButton, statusLabel });
    }

    private Button MakeButton(string text, Point location, EventHandler handler)
    {
        Button button = new Button { Text = text, Size = new Size(140, 34), Location = location };
        button.Click += handler;
        Controls.Add(button);
        return button;
    }

    private void Scan(object sender, EventArgs args)
    {
        if (scanning) return;
        scanning = true;
        scanButton.Enabled = false;
        statusLabel.Text = "正在扫描磁盘，请稍候...";
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
        }
        catch (Exception ex)
        {
            ScanFinished(-1, ex.Message);
        }
    }

    private void ScanFinished(int exitCode, string error = null)
    {
        scanning = false;
        scanButton.Enabled = true;
        if (exitCode == 0)
        {
            statusLabel.Text = "扫描完成，正在打开看板...";
            OpenDashboard(null, EventArgs.Empty);
        }
        else
        {
            statusLabel.Text = "扫描失败";
            string log = Path.Combine(DataPaths.Runtime, "last-run.log");
            string message = String.IsNullOrEmpty(error) ? "扫描未成功完成。" : error;
            if (File.Exists(log)) message += Environment.NewLine + Environment.NewLine + "日志：" + log;
            MessageBox.Show(message, "DiskPulse", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
        Process.Start(new ProcessStartInfo { FileName = dashboard, UseShellExecute = true });
        statusLabel.Text = "看板已打开";
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
        if (noOpen) info.EnvironmentVariables["DISKPULSE_NO_OPEN"] = "1";
        return Process.Start(info);
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
