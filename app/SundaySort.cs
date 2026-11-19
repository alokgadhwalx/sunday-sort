// SundaySort desktop app.
// Built with the C# compiler that ships with Windows (.NET Framework 4.x), so it needs nothing installed.
// The sorting itself is done by the tested PowerShell scripts next to this .exe; the app is a friendly
// front end: dashboard, clean-up review, history with undo, settings and a tray icon.
// Language level: C# 5 (no string interpolation, no ?. operator).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using WinForms = System.Windows.Forms;

[assembly: AssemblyTitle("SundaySort")]
[assembly: AssemblyProduct("SundaySort")]
[assembly: AssemblyDescription("Keeps your Downloads folder tidy")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace SundaySort
{
    // ------------------------------------------------------------------ data rows shown in the UI
    public class SourceRow { public string Name { get; set; } public double BarWidth { get; set; } public string CountText { get; set; } }
    public class RunRow
    {
        public string Title { get; set; } public string Detail { get; set; }
        public string LogFile { get; set; } public bool Undone { get; set; } public List<MoveRow> Moves { get; set; }
    }
    public class MoveRow { public string Name { get; set; } public string Folder { get; set; } public string Reason { get; set; } public long Bytes { get; set; } }
    public class CleanRow
    {
        public bool Selected { get; set; }
        public string Path { get; set; } public string Name { get; set; } public string Folder { get; set; }
        public string Category { get; set; } public long Bytes { get; set; } public string SizeText { get; set; }
        public string Reason { get; set; } public string KeptCopy { get; set; }
    }
    public class PsResult { public int ExitCode; public string Output; public string Error; }

    // ------------------------------------------------------------------ entry point
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            bool created;
            var mutex = new Mutex(true, "Local\\SundaySortApp", out created);
            var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\SundaySortAppShow");
            if (!created)
            {
                showSignal.Set();          // already running: bring that window to the front instead
                return 0;
            }
            try
            {
                var app = new Application();
                app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
                Theme.Apply(app);
                var ui = new MainUi(app, showSignal, args.Contains("--tray"));
                ui.Start();
                return app.Run();
            }
            catch (Exception ex)
            {
                MessageBox.Show("SundaySort couldn't start:\n\n" + ex.Message, "SundaySort", MessageBoxButton.OK, MessageBoxImage.Error);
                return 1;
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
    }

    // ------------------------------------------------------------------ colours (follows Windows light/dark)
    public static class Theme
    {
        public static bool Dark;
        public static void Apply(Application app)
        {
            Dark = true;
            try
            {
                var v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0);
                Dark = v == null || Convert.ToInt32(v) == 0;
            }
            catch { }
            var c = Dark
                ? new Dictionary<string, string> {
                    {"Bg","#17181C"},{"Sidebar","#1C1E23"},{"Surface","#22252B"},{"Surface2","#2C3038"},{"Line","#33363E"},
                    {"Text","#ECEEF2"},{"SubText","#9AA0AA"},{"Accent","#6C8CFF"},{"AccentText","#93ABFF"},{"OnAccent","#0E1220"},
                    {"Selected","#2F3A5C"},{"DangerText","#FF8A80"},{"Good","#4CC38A"} }
                : new Dictionary<string, string> {
                    {"Bg","#F6F7F9"},{"Sidebar","#EEF0F3"},{"Surface","#FFFFFF"},{"Surface2","#F0F2F5"},{"Line","#E1E4EA"},
                    {"Text","#1B1D22"},{"SubText","#5B6270"},{"Accent","#3D63F2"},{"AccentText","#2F54DF"},{"OnAccent","#FFFFFF"},
                    {"Selected","#E3E9FF"},{"DangerText","#C62828"},{"Good","#1E8E5A"} };
            foreach (var kv in c)
            {
                var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(kv.Value));
                b.Freeze();
                app.Resources[kv.Key] = b;
            }
        }
    }

    // ------------------------------------------------------------------ paths and the PowerShell engine
    public static class Engine
    {
        public const string WeeklyTask = "SundaySort - weekly Downloads cleanup";
        public const string LiveTask = "SundaySort - live Downloads sorting";
        public const string Version = "1.0.0";
        public const string RepoUrl = "https://github.com/alokgadhwalx/sunday-sort";

        public static readonly string ExeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        public static readonly string ScriptDir = FindScriptDir();
        public static readonly string DataDir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SundaySort");
        public static readonly string LogDir = System.IO.Path.Combine(DataDir, "logs");
        public static readonly string ReportDir = System.IO.Path.Combine(DataDir, "reports");
        public static string RulesFile { get { return System.IO.Path.Combine(ScriptDir, "rules.json"); } }

        static string FindScriptDir()
        {
            var d = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            for (int i = 0; i < 4 && d != null; i++, d = d.Parent)
                if (File.Exists(System.IO.Path.Combine(d.FullName, "Sort-Downloads.ps1"))) return d.FullName;
            return AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        }

        [DllImport("shell32.dll")]
        static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);

        public static string DownloadsFolder()
        {
            // If the tasks were installed for another folder (-Path), use that one.
            var args = TaskArguments(WeeklyTask) ?? TaskArguments(LiveTask) ?? "";
            var m = Regex.Match(args, "-Path\\s+\"([^\"]+)\"");
            if (m.Success) return m.Groups[1].Value;
            IntPtr p;
            if (SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out p) == 0)
            {
                var s = Marshal.PtrToStringUni(p);
                Marshal.FreeCoTaskMem(p);
                return s;
            }
            return System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }

        // ---- Task Scheduler (read-only and simple switches through COM)
        static dynamic Folder()
        {
            var t = Type.GetTypeFromProgID("Schedule.Service");
            dynamic svc = Activator.CreateInstance(t);
            svc.Connect();
            return svc.GetFolder("\\");
        }
        public static dynamic GetTask(string name)
        {
            try { return Folder().GetTask(name); } catch { return null; }
        }
        // 0 missing, 1 disabled, 3 ready, 4 running
        public static int TaskState(string name)
        {
            dynamic t = GetTask(name);
            if (t == null) return 0;
            try { return (int)t.State; } catch { return 0; }
        }
        public static DateTime? NextRun(string name)
        {
            dynamic t = GetTask(name);
            if (t == null) return null;
            try { DateTime d = t.NextRunTime; return d.Year > 2000 ? (DateTime?)d : null; } catch { return null; }
        }
        public static string TaskArguments(string name)
        {
            dynamic t = GetTask(name);
            if (t == null) return null;
            try { return (string)t.Definition.Actions.Item(1).Arguments; } catch { return null; }
        }
        public static void SetTaskEnabled(string name, bool on)
        {
            dynamic t = GetTask(name);
            if (t == null) return;
            if (!on) { try { t.Stop(0); } catch { } }
            t.Enabled = on;
            if (on && name == LiveTask) { try { t.Run(null); } catch { } }
        }

        // ---- PowerShell
        public static Task<PsResult> RunPowerShell(string arguments)
        {
            return Task.Run(() =>
            {
                var psi = new ProcessStartInfo("powershell.exe", arguments)
                {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                    WorkingDirectory = ScriptDir
                };
                using (var p = Process.Start(psi))
                {
                    var outTask = p.StandardOutput.ReadToEndAsync();
                    var errTask = p.StandardError.ReadToEndAsync();
                    p.WaitForExit();
                    return new PsResult { ExitCode = p.ExitCode, Output = outTask.Result, Error = errTask.Result };
                }
            });
        }
        public static Task<PsResult> RunScript(string script, string args)
        {
            return RunPowerShell("-NoProfile -ExecutionPolicy Bypass -File \"" + System.IO.Path.Combine(ScriptDir, script) + "\" " + args);
        }
        public static Task<PsResult> RunCommand(string command)
        {
            return RunPowerShell("-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
        }
        static string Q(string s) { return "'" + s.Replace("'", "''") + "'"; }

        // Options shared by every run, read from the installed weekly task, e.g. -RulesFile "..." -BySource
        public static string SharedOptions()
        {
            var a = TaskArguments(WeeklyTask) ?? TaskArguments(LiveTask) ?? "";
            var sb = new StringBuilder();
            var m = Regex.Match(a, "-RulesFile\\s+\"[^\"]+\"");
            if (m.Success) sb.Append(" " + m.Value);
            if (Regex.IsMatch(a, "\\s-BySource\\b")) sb.Append(" -BySource");
            m = Regex.Match(a, "-Path\\s+\"[^\"]+\"");
            if (m.Success) sb.Append(" " + m.Value);
            return sb.ToString();
        }
        public static bool HasOption(string flag)
        {
            var a = TaskArguments(WeeklyTask) ?? TaskArguments(LiveTask) ?? "";
            return Regex.IsMatch(a, "\\s" + Regex.Escape(flag) + "\\b");
        }

        // Adds or removes an option on both tasks and on the right-click menu, then restarts live mode.
        public static Task<PsResult> SetOption(string flag, string value, bool on)
        {
            var opt = value == null ? flag : flag + " \"" + value + "\"";
            var removeRx = value == null ? "\\s" + Regex.Escape(flag) + "\\b" : "\\s" + Regex.Escape(flag) + "\\s+\"[^\"]*\"";
            var ps = new StringBuilder();
            ps.AppendLine("$ErrorActionPreference = 'Stop'");
            ps.AppendLine("$rx = " + Q(removeRx) + "; $opt = " + Q(" " + opt) + "; $on = $" + (on ? "true" : "false"));
            ps.AppendLine("foreach ($n in " + Q(WeeklyTask) + ", " + Q(LiveTask) + ") {");
            ps.AppendLine("  $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; if (-not $t) { continue }");
            ps.AppendLine("  $a = $t.Actions[0]; $args2 = $a.Arguments -replace $rx, ''; if ($on) { $args2 += $opt }");
            ps.AppendLine("  $a.Arguments = $args2; Set-ScheduledTask -TaskName $n -Action $a | Out-Null }");
            ps.AppendLine("foreach ($k in 'HKCU:\\Software\\Classes\\Directory\\shell\\SundaySort\\command', 'HKCU:\\Software\\Classes\\Directory\\Background\\shell\\SundaySort\\command') {");
            ps.AppendLine("  if (Test-Path $k) { $v = (Get-Item $k).GetValue('') -replace $rx, ''; if ($on) { $v += $opt }; Set-Item -Path $k -Value $v } }");
            ps.AppendLine("$l = Get-ScheduledTask -TaskName " + Q(LiveTask) + " -ErrorAction SilentlyContinue");
            ps.AppendLine("if ($l -and $l.State -ne 'Disabled') { Stop-ScheduledTask -TaskName " + Q(LiveTask) + "; Start-Sleep -Milliseconds 800; Start-ScheduledTask -TaskName " + Q(LiveTask) + " }");
            return RunCommand(ps.ToString());
        }

        // Creates the live-mode task if SundaySort was installed without -Live.
        public static Task<PsResult> CreateLiveTask()
        {
            var watcher = System.IO.Path.Combine(ScriptDir, "Watch-Downloads.ps1");
            var args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + watcher + "\" -SettleSeconds 120 -Notify" + SharedOptions();
            var ps = new StringBuilder();
            ps.AppendLine("$ErrorActionPreference = 'Stop'");
            ps.AppendLine("$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name");
            ps.AppendLine("$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument " + Q(args));
            ps.AppendLine("$trg = @((New-ScheduledTaskTrigger -AtLogOn -User $me), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)))");
            ps.AppendLine("$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew");
            ps.AppendLine("$pr = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited");
            ps.AppendLine("Register-ScheduledTask -TaskName " + Q(LiveTask) + " -Description 'Sorts new downloads shortly after they finish. Never deletes anything.' -Action $act -Trigger $trg -Settings $set -Principal $pr -Force | Out-Null");
            ps.AppendLine("Start-ScheduledTask -TaskName " + Q(LiveTask));
            return RunCommand(ps.ToString());
        }

        public static Task<PsResult> ValidateJson(string file)
        {
            return RunCommand("$null = Get-Content -LiteralPath " + Q(file) + " -Raw | ConvertFrom-Json");
        }
    }

    // ------------------------------------------------------------------ small helpers
    public static class Util
    {
        public static string Size(double bytes)
        {
            if (bytes >= 1024.0 * 1024 * 1024) return (bytes / (1024.0 * 1024 * 1024)).ToString("N1") + " GB";
            if (bytes >= 1024.0 * 1024) return (bytes / (1024.0 * 1024)).ToString("N0") + " MB";
            return Math.Max(1, bytes / 1024.0).ToString("N0") + " KB";
        }
        public static string Plural(int n, string one, string many) { return n == 1 ? "1 " + one : n.ToString("N0") + " " + many; }

        // Minimal CSV reader for the files PowerShell's Export-Csv writes.
        public static List<Dictionary<string, string>> ReadCsv(string file)
        {
            var rows = new List<Dictionary<string, string>>();
            string text;
            try { text = File.ReadAllText(file, Encoding.UTF8); } catch { return rows; }
            var records = new List<List<string>>();
            var cur = new List<string>(); var field = new StringBuilder(); bool inQ = false;
            for (int i = 0; i < text.Length; i++)
            {
                char ch = text[i];
                if (inQ)
                {
                    if (ch == '"') { if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; } else inQ = false; }
                    else field.Append(ch);
                }
                else if (ch == '"') inQ = true;
                else if (ch == ',') { cur.Add(field.ToString()); field.Clear(); }
                else if (ch == '\n') { cur.Add(field.ToString()); field.Clear(); records.Add(cur); cur = new List<string>(); }
                else if (ch != '\r') field.Append(ch);
            }
            if (field.Length > 0 || cur.Count > 0) { cur.Add(field.ToString()); records.Add(cur); }
            if (records.Count == 0) return rows;
            var head = records[0].Select(h => h.Trim('\uFEFF')).ToList();
            for (int r = 1; r < records.Count; r++)
            {
                if (records[r].Count == 1 && records[r][0] == "") continue;
                var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int c = 0; c < head.Count; c++) d[head[c]] = c < records[r].Count ? records[r][c] : "";
                rows.Add(d);
            }
            return rows;
        }
        public static string Get(Dictionary<string, string> d, string key) { string v; return d.TryGetValue(key, out v) ? v : ""; }

        public static void Open(string target)
        {
            try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
        }
    }

    // ------------------------------------------------------------------ download sources (Mark of the Web)
    public static class Sources
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

        static readonly string[][] Known = {
            new[] {"WhatsApp", "whatsapp.com", "whatsapp.net"},
            new[] {"Gmail", "mail.google.com", "mail-attachment.googleusercontent.com"},
            new[] {"Google Drive", "drive.google.com", "drive.usercontent.google.com", "docs.google.com"},
            new[] {"Outlook", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "attachments.office.net"},
            new[] {"Teams", "teams.microsoft.com", "teams.live.com"},
            new[] {"OneDrive / SharePoint", "onedrive.live.com", "1drv.ms", "sharepoint.com"},
            new[] {"Discord", "discord.com", "discordapp.com", "discordapp.net"},
            new[] {"Telegram", "telegram.org"},
            new[] {"Slack", "slack.com", "slack-edge.com", "slack-files.com"},
            new[] {"GitHub", "github.com", "githubusercontent.com"},
            new[] {"LinkedIn", "linkedin.com", "licdn.com"},
            new[] {"Canva", "canva.com"},
            new[] {"Office Online", "officeapps.live.com", "office.com", "microsoft365.com"},
            new[] {"ChatGPT", "chatgpt.com", "oaiusercontent.com"},
            new[] {"Claude", "claude.ai"},
        };

        public static string HostOf(string file)
        {
            // GENERIC_READ, share read/write/delete, OPEN_EXISTING
            using (var h = CreateFileW(file + ":Zone.Identifier", 0x80000000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero))
            {
                if (h.IsInvalid) return null;
                string text;
                using (var fs = new FileStream(h, FileAccess.Read))
                using (var sr = new StreamReader(fs)) text = sr.ReadToEnd();
                string referrer = null, hostUrl = null;
                foreach (var line in text.Split('\n'))
                {
                    var l = line.Trim();
                    if (l.StartsWith("ReferrerUrl=", StringComparison.OrdinalIgnoreCase)) referrer = l.Substring(12);
                    else if (l.StartsWith("HostUrl=", StringComparison.OrdinalIgnoreCase)) hostUrl = l.Substring(8);
                }
                foreach (var u in new[] { referrer, hostUrl })
                {
                    if (string.IsNullOrEmpty(u)) continue;
                    Uri uri;
                    var s = u.StartsWith("blob:", StringComparison.OrdinalIgnoreCase) ? u.Substring(5) : u;
                    if (Uri.TryCreate(s, UriKind.Absolute, out uri) && !string.IsNullOrEmpty(uri.Host) && uri.Host != "about")
                        return uri.Host.ToLowerInvariant();
                }
                return null;
            }
        }

        public static string Label(string host)
        {
            foreach (var k in Known)
                for (int i = 1; i < k.Length; i++)
                    if (host == k[i] || host.EndsWith("." + k[i])) return k[0];
            return host.StartsWith("www.") ? host.Substring(4) : host;
        }

        // Counts where the files in Downloads (and its sorted subfolders) came from.
        public static List<KeyValuePair<string, int>> Count(string root, out int total, out int tagged)
        {
            var counts = new Dictionary<string, int>();
            total = 0; tagged = 0;
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories); } catch { return new List<KeyValuePair<string, int>>(); }
            try
            {
                foreach (var f in files)
                {
                    total++;
                    string host = null;
                    try { host = HostOf(f); } catch { }
                    if (host == null) continue;
                    tagged++;
                    var label = Label(host);
                    int n; counts.TryGetValue(label, out n); counts[label] = n + 1;
                    if (total > 20000) break;
                }
            }
            catch { }   // a folder we can't read: use what we counted so far
            return counts.OrderByDescending(kv => kv.Value).ToList();
        }
    }

    // ------------------------------------------------------------------ the window
    public class MainUi
    {
        readonly Application app;
        readonly EventWaitHandle showSignal;
        readonly bool startHidden;
        Window win;
        WinForms.NotifyIcon tray;
        WinForms.ToolStripMenuItem trayPause;
        DispatcherTimer refreshTimer, toastTimer;
        bool loadingSettings, quitting, trayHintShown;
        DateTime lastLiveKick = DateTime.MinValue;
        List<CleanRow> cleanRows = new List<CleanRow>();
        string downloads;

        public MainUi(Application app, EventWaitHandle showSignal, bool startHidden)
        {
            this.app = app; this.showSignal = showSignal; this.startHidden = startHidden;
        }

        T F<T>(string name) where T : class { return win.FindName(name) as T; }

        public void Start()
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("MainWindow.xaml"))
                win = (Window)XamlReader.Load(s);
            downloads = Engine.DownloadsFolder();

            var logo = LoadLogo();
            if (logo != null) { F<Image>("Logo").Source = logo; win.Icon = logo; }
            win.SourceInitialized += (s, e) => DarkTitleBar();
            win.Closing += (s, e) =>
            {
                if (quitting) return;
                e.Cancel = true;
                win.Hide();
                if (!trayHintShown) { trayHintShown = true; tray.ShowBalloonTip(3000, "SundaySort is still here", "It's in the tray. Live sorting keeps running either way.", WinForms.ToolTipIcon.Info); }
            };
            win.Activated += (s, e) => RefreshDashboard();

            WireNavigation();
            WireDashboard();
            WireCleanup();
            WireHistory();
            WireSettings();
            SetupTray();

            refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
            refreshTimer.Tick += (s, e) => { if (win.IsVisible) RefreshDashboard(); };
            refreshTimer.Start();

            // Second launch of the app -> show this window
            var t = new Thread(() =>
            {
                while (true)
                {
                    showSignal.WaitOne();
                    app.Dispatcher.BeginInvoke(new Action(ShowWindow));
                }
            });
            t.IsBackground = true; t.Start();

            if (!startHidden) ShowWindow();
            RefreshDashboard();
            LoadSources();
        }

        BitmapSource LoadLogo()
        {
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("logo.png"))
                {
                    if (s == null) return null;
                    var b = new BitmapImage();
                    b.BeginInit(); b.StreamSource = s; b.CacheOption = BitmapCacheOption.OnLoad; b.EndInit(); b.Freeze();
                    return b;
                }
            }
            catch { return null; }
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        void DarkTitleBar()
        {
            if (!Theme.Dark) return;
            int on = 1;
            var h = new WindowInteropHelper(win).Handle;
            if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4);
        }

        void ShowWindow()
        {
            win.Show();
            if (win.WindowState == WindowState.Minimized) win.WindowState = WindowState.Normal;
            win.Activate(); win.Topmost = true; win.Topmost = false; win.Focus();
        }

        void Quit()
        {
            quitting = true;
            tray.Visible = false; tray.Dispose();
            app.Shutdown();
        }

        void Toast(string text)
        {
            F<TextBlock>("ToastText").Text = text;
            F<Border>("Toast").Visibility = Visibility.Visible;
            if (toastTimer == null)
            {
                toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
                toastTimer.Tick += (s, e) => { toastTimer.Stop(); F<Border>("Toast").Visibility = Visibility.Collapsed; };
            }
            toastTimer.Stop(); toastTimer.Start();
        }

        // ================================================================ navigation
        void WireNavigation()
        {
            var pages = new Dictionary<string, string> { { "NavDash", "PageDash" }, { "NavClean", "PageClean" }, { "NavHistory", "PageHistory" }, { "NavSettings", "PageSettings" } };
            foreach (var kv in pages)
            {
                var page = kv.Value;
                F<RadioButton>(kv.Key).Checked += (s, e) =>
                {
                    foreach (var p in pages.Values) F<FrameworkElement>(p).Visibility = p == page ? Visibility.Visible : Visibility.Collapsed;
                    if (page == "PageDash") RefreshDashboard();
                    if (page == "PageClean") LoadCleanup(false);
                    if (page == "PageHistory") LoadHistory();
                    if (page == "PageSettings") LoadSettings();
                };
            }
        }
        void GoTo(string nav) { F<RadioButton>(nav).IsChecked = true; }

        // ================================================================ dashboard
        void WireDashboard()
        {
            F<TextBlock>("DownloadsPath").Text = downloads;
            F<Button>("OpenDownloads").Click += (s, e) => Util.Open(downloads);
            F<Button>("SortNow").Click += (s, e) => SortNow();
            F<Button>("CardFreeLink").Click += (s, e) => GoTo("NavClean");
        }

        async void SortNow()
        {
            var btn = F<Button>("SortNow");
            btn.IsEnabled = false; btn.Content = "Sorting…";
            var r = await Engine.RunScript("Sort-Downloads.ps1", "-MinAgeMinutes 0.5" + Engine.SharedOptions());
            btn.IsEnabled = true; btn.Content = "Sort now";
            var m = Regex.Match(r.Output ?? "", "Moved (\\d+) files");
            if (r.ExitCode != 0) Toast("Sorting failed: " + FirstLine(r.Error));
            else if (m.Success) Toast("Sorted " + m.Groups[1].Value + " files. You can undo this in History.");
            else Toast("Nothing to sort right now.");
            RefreshDashboard(); LoadSources();
        }

        static string FirstLine(string s) { return (s ?? "").Split('\n').Select(x => x.Trim()).FirstOrDefault(x => x.Length > 0) ?? "unknown error"; }

        void RefreshDashboard()
        {
            // Loose files waiting
            int loose = 0;
            try
            {
                foreach (var f in new DirectoryInfo(downloads).EnumerateFiles())
                    if ((f.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0 && !f.Name.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)) loose++;
            }
            catch { }
            F<TextBlock>("CardLoose").Text = loose.ToString("N0");
            F<TextBlock>("CardLooseSub").Text = loose == 0 ? "All tidy" : (loose == 1 ? "loose file in Downloads" : "loose files in Downloads");

            // Running total
            var statsFile = System.IO.Path.Combine(Engine.LogDir, "stats.json");
            long files = 0, bytes = 0; string since = null;
            try
            {
                var j = File.ReadAllText(statsFile);
                var m1 = Regex.Match(j, "\"Files\"\\s*:\\s*(\\d+)"); if (m1.Success) files = long.Parse(m1.Groups[1].Value);
                var m2 = Regex.Match(j, "\"Bytes\"\\s*:\\s*(\\d+)"); if (m2.Success) bytes = long.Parse(m2.Groups[1].Value);
                var m3 = Regex.Match(j, "\"Since\"\\s*:\\s*\"([^\"]+)\""); if (m3.Success) since = m3.Groups[1].Value;
            }
            catch { }
            F<TextBlock>("CardSorted").Text = files.ToString("N0");
            DateTime sd;
            F<TextBlock>("CardSortedSub").Text = files == 0 ? "files so far"
                : (files == 1 ? "file (" : "files (") + Util.Size(bytes) + ")" + (since != null && DateTime.TryParse(since, out sd) ? " since " + sd.ToString("d MMM") : "");

            // Reclaimable, from the latest report
            var rows = LatestReport();
            var live = rows.Where(r => File.Exists(r.Path)).ToList();
            if (rows.Count == 0 && !Directory.Exists(Engine.ReportDir))
            {
                F<TextBlock>("CardFree").Text = "?";
                F<TextBlock>("CardFreeSub").Text = "Scan now →";
            }
            else
            {
                F<TextBlock>("CardFree").Text = live.Count == 0 ? "0 KB" : Util.Size(live.Sum(r => r.Bytes));
                F<TextBlock>("CardFreeSub").Text = live.Count == 0 ? "Nothing to clean up →" : "Review " + Util.Plural(live.Count, "file", "files") + " →";
            }

            // Live mode / weekly status. If live mode is switched on but its watcher isn't running
            // (it was closed for some reason), start it again.
            var state = Engine.TaskState(Engine.LiveTask);
            if (state == 3 && (DateTime.Now - lastLiveKick).TotalMinutes > 1)
            {
                lastLiveKick = DateTime.Now;
                try { dynamic t = Engine.GetTask(Engine.LiveTask); t.Run(null); } catch { }
            }
            string liveText, liveSub; Brush dot;
            if (state == 4) { liveText = "On"; liveSub = "Sorting new downloads as they arrive"; dot = (Brush)app.Resources["Good"]; }
            else if (state == 1) { liveText = "Paused"; liveSub = "Turn it on in Settings"; dot = (Brush)app.Resources["SubText"]; }
            else if (state == 3) { liveText = "Starting"; liveSub = "Starts when you log in"; dot = (Brush)app.Resources["SubText"]; }
            else { liveText = "Off"; liveSub = "Only the Sunday check-up runs"; dot = (Brush)app.Resources["SubText"]; }
            F<TextBlock>("CardLive").Text = liveText;
            F<TextBlock>("CardLiveSub").Text = liveSub;
            F<TextBlock>("LiveLabel").Text = state == 4 ? "Live sorting on" : "Live sorting " + liveText.ToLower();
            F<System.Windows.Shapes.Ellipse>("LiveDot").Fill = dot;
            var next = Engine.NextRun(Engine.WeeklyTask);
            F<TextBlock>("LiveHint").Text = next.HasValue ? "Next check-up: " + next.Value.ToString("ddd d MMM, HH:mm") : "Sunday check-up is off";
            if (trayPause != null) trayPause.Text = state == 1 ? "Resume live sorting" : "Pause live sorting";

            // Recent activity
            var runs = ReadRuns().Take(4).ToList();
            F<ItemsControl>("RecentList").ItemsSource = runs;
            F<TextBlock>("RecentEmpty").Visibility = runs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        async void LoadSources()
        {
            F<TextBlock>("SourcesNote").Text = "Reading download sources…";
            int total = 0, tagged = 0;
            var root = downloads;
            var counts = await Task.Run(() => Sources.Count(root, out total, out tagged));
            if (total == 0) { F<TextBlock>("SourcesNote").Text = "No files in Downloads yet."; F<ItemsControl>("SourcesList").ItemsSource = null; return; }
            var top = counts.Take(6).ToList();
            int other = counts.Skip(6).Sum(kv => kv.Value);
            var rows = top.Select(kv => new KeyValuePair<string, int>(kv.Key, kv.Value)).ToList();
            if (other > 0) rows.Add(new KeyValuePair<string, int>("Other sites", other));
            rows.Add(new KeyValuePair<string, int>("No source recorded", total - tagged));
            int max = Math.Max(1, rows.Max(r => r.Value));
            F<ItemsControl>("SourcesList").ItemsSource = rows.Select(r => new SourceRow
            {
                Name = r.Key, CountText = r.Value.ToString("N0"), BarWidth = Math.Max(4, 280.0 * r.Value / max)
            }).ToList();
            F<TextBlock>("SourcesNote").Text = string.Format("{0:N0} of your {1:N0} downloads ({2:P0}) recorded the website they came from. Turn on 'Sort by website' in Settings to use it.",
                tagged, total, (double)tagged / total);
        }

        // ================================================================ clean up
        void WireCleanup()
        {
            F<Button>("ScanNow").Click += (s, e) => LoadCleanup(true);
            F<CheckBox>("SelectAll").Click += (s, e) =>
            {
                bool on = F<CheckBox>("SelectAll").IsChecked == true;
                foreach (var r in cleanRows) r.Selected = on;
                F<ItemsControl>("CleanList").ItemsSource = null; F<ItemsControl>("CleanList").ItemsSource = cleanRows;
                UpdateSelection();
            };
            F<ItemsControl>("CleanList").AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler((s, e) => UpdateSelection()));
            F<Button>("RecycleSelected").Click += (s, e) => RecycleSelected();
        }

        List<CleanRow> LatestReport()
        {
            var list = new List<CleanRow>();
            try
            {
                if (!Directory.Exists(Engine.ReportDir)) return list;
                var latest = new DirectoryInfo(Engine.ReportDir).GetFiles("report-*.csv").OrderByDescending(f => f.Name).FirstOrDefault();
                if (latest == null) return list;
                foreach (var d in Util.ReadCsv(latest.FullName))
                {
                    long b; long.TryParse(Util.Get(d, "Bytes"), out b);
                    var p = Util.Get(d, "Path");
                    list.Add(new CleanRow
                    {
                        Path = p, Name = System.IO.Path.GetFileName(p),
                        Folder = ShortFolder(System.IO.Path.GetDirectoryName(p)),
                        Category = Util.Get(d, "Category") == "Extracted archive" ? "Unzipped archive" : Util.Get(d, "Category") == "Installer" ? "Old installer" : Util.Get(d, "Category"),
                        Bytes = b, SizeText = Util.Size(b), Reason = Util.Get(d, "Reason"), KeptCopy = Util.Get(d, "KeptCopy"),
                        Selected = true
                    });
                }
            }
            catch { }
            return list;
        }

        string ShortFolder(string dir)
        {
            if (dir == null) return "";
            if (dir.StartsWith(downloads, StringComparison.OrdinalIgnoreCase)) return "Downloads" + dir.Substring(downloads.Length);
            return dir;
        }

        async void LoadCleanup(bool rescan)
        {
            var rows = rescan ? new List<CleanRow>() : LatestReport();
            if (rescan || !Directory.Exists(Engine.ReportDir) || new DirectoryInfo(Engine.ReportDir).GetFiles("report-*.csv").Length == 0)
            {
                F<Button>("ScanNow").IsEnabled = false; F<Button>("ScanNow").Content = "Scanning…";
                F<TextBlock>("CleanEmpty").Text = "Looking for old installers, unzipped archives and duplicates…";
                F<TextBlock>("CleanEmpty").Visibility = Visibility.Visible;
                F<ItemsControl>("CleanList").ItemsSource = null;
                var opts = Engine.SharedOptions();
                var rules = Regex.Match(opts, "-RulesFile\\s+\"[^\"]+\"").Value;
                var path = Regex.Match(opts, "-Path\\s+\"[^\"]+\"").Value;
                var r = await Engine.RunScript("Find-Reclaimable.ps1", (rules + " " + path).Trim());
                F<Button>("ScanNow").IsEnabled = true; F<Button>("ScanNow").Content = "Scan again";
                if (r.ExitCode != 0)
                {
                    // Show the problem instead of an older report
                    cleanRows = new List<CleanRow>();
                    F<ItemsControl>("CleanList").ItemsSource = null;
                    F<TextBlock>("CleanEmpty").Text = "The scan didn't work: " + FirstLine(r.Error);
                    F<TextBlock>("CleanEmpty").Visibility = Visibility.Visible;
                    UpdateSelection();
                    return;
                }
                rows = LatestReport();
                // A clean scan writes no report: make sure we don't show an old one
                if ((r.Output ?? "").Contains("Nothing reclaimable")) rows = new List<CleanRow>();
            }
            cleanRows = rows.Where(x => File.Exists(x.Path)).ToList();
            F<ItemsControl>("CleanList").ItemsSource = cleanRows;
            F<CheckBox>("SelectAll").IsChecked = cleanRows.Count > 0;
            F<TextBlock>("CleanEmpty").Text = "Nothing to clean up. Your Downloads folder has no old installers, unzipped archives or duplicates.";
            F<TextBlock>("CleanEmpty").Visibility = cleanRows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateSelection();
            RefreshDashboard();
        }

        void UpdateSelection()
        {
            var sel = cleanRows.Where(r => r.Selected).ToList();
            F<Button>("RecycleSelected").IsEnabled = sel.Count > 0;
            F<TextBlock>("SelectedText").Text = sel.Count == 0
                ? "Tick the files you want to remove. They go to the Recycle Bin, so you can restore them."
                : Util.Plural(sel.Count, "file", "files") + " selected · " + Util.Size(sel.Sum(r => r.Bytes)) + " · they go to the Recycle Bin, so you can restore them.";
        }

        void RecycleSelected()
        {
            var sel = cleanRows.Where(r => r.Selected).ToList();
            if (sel.Count == 0) return;
            var ok = MessageBox.Show(win, "Move " + Util.Plural(sel.Count, "file", "files") + " (" + Util.Size(sel.Sum(r => r.Bytes)) + ") to the Recycle Bin?\n\nYou can restore them from the Recycle Bin if you need them.",
                "SundaySort", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (ok != MessageBoxResult.OK) return;
            int moved = 0, skipped = 0; long freed = 0;
            foreach (var r in sel)
            {
                try
                {
                    var fi = new FileInfo(r.Path);
                    // Same safety checks as Remove-Reclaimable.ps1
                    if (!fi.Exists || fi.Length != r.Bytes) { skipped++; continue; }
                    if (r.Category == "Duplicate" && (string.IsNullOrEmpty(r.KeptCopy) || !File.Exists(r.KeptCopy))) { skipped++; continue; }
                    Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(r.Path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
                    moved++; freed += r.Bytes;
                }
                catch { skipped++; }
            }
            cleanRows = cleanRows.Where(r => File.Exists(r.Path)).ToList();
            F<ItemsControl>("CleanList").ItemsSource = cleanRows;
            F<CheckBox>("SelectAll").IsChecked = cleanRows.Count > 0 && cleanRows.All(r => r.Selected);
            F<TextBlock>("CleanEmpty").Visibility = cleanRows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateSelection(); RefreshDashboard();
            Toast("Moved " + Util.Plural(moved, "file", "files") + " (" + Util.Size(freed) + ") to the Recycle Bin" + (skipped > 0 ? " · skipped " + skipped + " that had changed" : "") + ".");
        }

        // ================================================================ history
        void WireHistory()
        {
            var list = F<ListBox>("RunList");
            list.SelectionChanged += (s, e) =>
            {
                var run = list.SelectedItem as RunRow;
                F<ItemsControl>("MoveList").ItemsSource = run == null ? null : run.Moves;
                F<TextBlock>("RunTitle").Text = run == null ? "Pick a sort on the left" : run.Title + (run.Undone ? " · undone" : "");
                F<Button>("UndoRun").IsEnabled = run != null && !run.Undone;
            };
            F<Button>("UndoRun").Click += async (s, e) =>
            {
                var run = list.SelectedItem as RunRow;
                if (run == null) return;
                if (MessageBox.Show(win, "Put the " + Util.Plural(run.Moves.Count, "file", "files") + " from this sort back where they were?", "SundaySort",
                    MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
                F<Button>("UndoRun").IsEnabled = false;
                var r = await Engine.RunScript("Undo-LastSort.ps1", "-LogFile \"" + run.LogFile + "\"");
                var m = Regex.Match(r.Output ?? "", "Restored (\\d+) files");
                Toast(r.ExitCode != 0 ? "Undo failed: " + FirstLine(r.Error) : "Put back " + (m.Success ? m.Groups[1].Value : "0") + " files.");
                LoadHistory(); RefreshDashboard();
            };
        }

        IEnumerable<RunRow> ReadRuns()
        {
            if (!Directory.Exists(Engine.LogDir)) yield break;
            var files = new DirectoryInfo(Engine.LogDir).GetFiles("sort-*.csv").OrderByDescending(f => f.Name.Replace(".undone", "")).ToList();
            foreach (var f in files)
            {
                var m = Regex.Match(f.Name, "sort-(\\d{8}-\\d{6})");
                DateTime when;
                if (!m.Success || !DateTime.TryParseExact(m.Groups[1].Value, "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out when)) continue;
                var moves = Util.ReadCsv(f.FullName).Select(d =>
                {
                    long b; long.TryParse(Util.Get(d, "Bytes"), out b);
                    var to = Util.Get(d, "To");
                    var folder = Util.Get(d, "Folder");
                    if (folder == "") folder = ShortFolder(System.IO.Path.GetDirectoryName(to));
                    return new MoveRow { Name = System.IO.Path.GetFileName(to), Folder = folder, Reason = Util.Get(d, "Reason"), Bytes = b };
                }).ToList();
                if (moves.Count == 0) continue;
                var top = moves.GroupBy(x => x.Folder.Split('\\').Last()).OrderByDescending(g => g.Count()).Take(3).Select(g => g.Key + " " + g.Count());
                bool undone = f.Name.Contains(".undone");
                yield return new RunRow
                {
                    Title = (when.Date == DateTime.Today ? "Today, " + when.ToString("HH:mm") : when.Date == DateTime.Today.AddDays(-1) ? "Yesterday, " + when.ToString("HH:mm") : when.ToString("ddd d MMM, HH:mm")),
                    Detail = Util.Plural(moves.Count, "file", "files") + " · " + string.Join(", ", top) + (undone ? " · undone" : ""),
                    LogFile = f.FullName, Undone = undone, Moves = moves
                };
            }
        }

        void LoadHistory()
        {
            var runs = ReadRuns().ToList();
            F<ListBox>("RunList").ItemsSource = runs;
            F<TextBlock>("HistoryEmpty").Visibility = runs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (runs.Count > 0) F<ListBox>("RunList").SelectedIndex = 0;
        }

        // ================================================================ settings
        void WireSettings()
        {
            F<CheckBox>("SetLive").Click += async (s, e) =>
            {
                if (loadingSettings) return;
                bool on = F<CheckBox>("SetLive").IsChecked == true;
                if (on && Engine.TaskState(Engine.LiveTask) == 0)
                {
                    var r = await Engine.CreateLiveTask();
                    Toast(r.ExitCode == 0 ? "Live sorting is on." : "Couldn't turn on live sorting: " + FirstLine(r.Error));
                }
                else { Engine.SetTaskEnabled(Engine.LiveTask, on); Toast(on ? "Live sorting is on." : "Live sorting is paused."); }
                await Task.Delay(1500); LoadSettings(); RefreshDashboard();
            };
            F<CheckBox>("SetWeekly").Click += (s, e) =>
            {
                if (loadingSettings) return;
                bool on = F<CheckBox>("SetWeekly").IsChecked == true;
                Engine.SetTaskEnabled(Engine.WeeklyTask, on);
                Toast(on ? "Sunday check-up is on." : "Sunday check-up is off.");
                LoadSettings(); RefreshDashboard();
            };
            F<CheckBox>("SetSource").Click += async (s, e) =>
            {
                if (loadingSettings) return;
                bool on = F<CheckBox>("SetSource").IsChecked == true;
                F<CheckBox>("SetSource").IsEnabled = false;
                var r = await Engine.SetOption("-BySource", null, on);
                F<CheckBox>("SetSource").IsEnabled = true;
                Toast(r.ExitCode == 0 ? (on ? "New downloads from well-known sites now go to 'From …' folders." : "Sorting by website is off.") : "Couldn't change this: " + FirstLine(r.Error));
                LoadSettings();
            };
            F<Button>("EditRules").Click += (s, e) => EditRules();
            F<Button>("OpenLogs").Click += (s, e) => { Directory.CreateDirectory(Engine.DataDir); Util.Open(Engine.DataDir); };
            F<Button>("OpenInstall").Click += (s, e) => Util.Open(Engine.ScriptDir);
            F<Button>("OpenRepo").Click += (s, e) => Util.Open(Engine.RepoUrl);
            F<Button>("UninstallBtn").Click += (s, e) => Uninstall();
        }

        void LoadSettings()
        {
            loadingSettings = true;
            var live = Engine.TaskState(Engine.LiveTask);
            var weekly = Engine.TaskState(Engine.WeeklyTask);
            F<CheckBox>("SetLive").IsChecked = live == 3 || live == 4;
            F<CheckBox>("SetWeekly").IsChecked = weekly == 3 || weekly == 4;
            F<CheckBox>("SetWeekly").IsEnabled = weekly != 0;
            F<CheckBox>("SetSource").IsChecked = Engine.HasOption("-BySource");
            F<CheckBox>("SetSource").IsEnabled = weekly != 0 || live != 0;
            var next = Engine.NextRun(Engine.WeeklyTask);
            F<TextBlock>("SetWeeklySub").Text = "Every Sunday: sort anything left over and look for space you could free." +
                (next.HasValue ? " Next: " + next.Value.ToString("ddd d MMM, HH:mm") + "." : "");
            F<TextBlock>("RulesSub").Text = File.Exists(Engine.RulesFile)
                ? "Using your rules file. Send files to your own folders by name (*invoice* → Finance), by website, or by type."
                : "Send files to your own folders by name (e.g. *invoice* → Finance), by website, or by type.";
            F<TextBlock>("AboutText").Text = "SundaySort " + Engine.Version + " · free and open source (MIT)\nInstalled in " + Engine.ScriptDir + "\nLogs and reports in " + Engine.DataDir;
            loadingSettings = false;
        }

        async void EditRules()
        {
            var file = Engine.RulesFile;
            if (!File.Exists(file))
            {
                File.WriteAllText(file,
                    "{\r\n" +
                    "  \"_help\": \"names: file-name patterns -> folder.  sources: website -> folder.  folders: extensions -> folder.  Example: \\\"names\\\": { \\\"Finance\\\": [\\\"*invoice*\\\", \\\"*receipt*\\\"] }\",\r\n" +
                    "  \"names\": { },\r\n  \"sources\": { },\r\n  \"folders\": { }\r\n}\r\n", new UTF8Encoding(false));
                await Engine.SetOption("-RulesFile", file, true);
            }
            else if (!Regex.IsMatch(Engine.SharedOptions(), "-RulesFile"))
            {
                await Engine.SetOption("-RulesFile", file, true);
            }
            var p = Process.Start("notepad.exe", "\"" + file + "\"");
            Toast("Save and close Notepad when you're done. Changes apply to the next sort.");
            await Task.Run(() => p.WaitForExit());
            var v = await Engine.ValidateJson(file);
            if (v.ExitCode != 0)
            {
                MessageBox.Show(win, "Your rules file has a mistake, so sorting will stop until it's fixed:\n\n" + FirstLine(v.Error) +
                    "\n\nClick Edit rules again to fix it.", "SundaySort", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            else Toast("Rules saved.");
            LoadSettings();
        }

        void Uninstall()
        {
            if (MessageBox.Show(win, "Remove SundaySort from this PC?\n\nThis stops live sorting, removes the Sunday check-up, the right-click menu and the app. Your files stay exactly where they are.",
                "Uninstall SundaySort", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
            var script = System.IO.Path.Combine(Engine.ScriptDir, "Uninstall.ps1");
            // Run after the app has closed, so the uninstaller can remove SundaySort.exe too.
            var cmd = "Start-Sleep -Seconds 2; & '" + script.Replace("'", "''") + "'";
            Process.Start(new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(cmd)))
                { UseShellExecute = false, CreateNoWindow = true });
            Quit();
        }

        // ================================================================ tray icon
        void SetupTray()
        {
            tray = new WinForms.NotifyIcon();
            try { tray.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { tray.Icon = System.Drawing.SystemIcons.Application; }
            tray.Text = "SundaySort";
            var menu = new WinForms.ContextMenuStrip();
            menu.Items.Add("Open SundaySort", null, (s, e) => ShowWindow());
            menu.Items.Add("Sort now", null, (s, e) => SortNow());
            trayPause = new WinForms.ToolStripMenuItem("Pause live sorting", null, (s, e) =>
            {
                bool paused = Engine.TaskState(Engine.LiveTask) == 1;
                Engine.SetTaskEnabled(Engine.LiveTask, paused);
                tray.ShowBalloonTip(2000, "SundaySort", paused ? "Live sorting is on." : "Live sorting is paused.", WinForms.ToolTipIcon.None);
                RefreshDashboard();
            });
            menu.Items.Add(trayPause);
            menu.Items.Add(new WinForms.ToolStripSeparator());
            menu.Items.Add("Quit the app (sorting keeps running)", null, (s, e) => Quit());
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += (s, e) => ShowWindow();
            tray.Visible = true;
        }
    }
}
