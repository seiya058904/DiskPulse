using System;
using System.Collections;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Resources;
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
        "DiskPulse", "app");

    internal static void EnsureExtracted()
    {
        Directory.CreateDirectory(Root);
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DiskPulse.Payload"))
        using (ResourceReader reader = new ResourceReader(stream))
        {
            foreach (DictionaryEntry entry in reader)
            {
                string path = Path.Combine(Root, (string)entry.Key);
                File.WriteAllBytes(path, (byte[])entry.Value);
            }
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
        Directory.CreateDirectory(Runtime);
        MigrateDirectory(Path.Combine(appRoot, "runtime"), Runtime);
        MigrateDirectory(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "runtime"), Runtime);

        string marker = Path.Combine(Root, "migration-sources.txt");
        if (File.Exists(marker))
        {
            foreach (string source in File.ReadAllLines(marker))
            {
                if (!String.IsNullOrWhiteSpace(source)) MigrateDirectory(source.Trim(), Runtime);
            }
            File.Delete(marker);
        }
    }

    internal static void MigrateDirectory(string source, string destination)
    {
        if (!Directory.Exists(source)) return;
        foreach (string file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            string relative = file.Substring(source.TrimEnd(Path.DirectorySeparatorChar).Length).TrimStart(Path.DirectorySeparatorChar);
            string target = Path.Combine(destination, relative);
            if (File.Exists(target)) continue;
            string parent = Path.GetDirectoryName(target);
            if (!String.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
            File.Copy(file, target);
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
            Process process = Start("wscript.exe", Quote(Path.Combine(root, "DiskPulse.vbs")), true);
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

    private static Process Start(string fileName, string arguments, bool hidden)
    {
        return Process.Start(new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = Payload.Root,
            UseShellExecute = false,
            CreateNoWindow = hidden,
            WindowStyle = hidden ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal
        });
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
