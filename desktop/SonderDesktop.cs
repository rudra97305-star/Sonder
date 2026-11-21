using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: AssemblyTitle("Sonder")]
[assembly: AssemblyProduct("Sonder Audio Studio")]
[assembly: AssemblyDescription("Download and separate tracks in the Sonder desktop studio.")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Desktop
{
    private const string ResourcePrefix = "Sonder.Desktop.";

    [STAThread]
    private static int Main()
    {
        AppDomain.CurrentDomain.AssemblyResolve += ResolveWebViewAssembly;
        try
        {
            string workspace = FindWorkspace();
            using (var instance = new Mutex(false, @"Local\Sonder-" + WorkspaceKey(workspace)))
            {
                bool acquired;
                try { acquired = instance.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired)
                {
                    MessageBox.Show("Sonder is already open.", "Sonder");
                    return 0;
                }
                try { RunWindow(workspace); }
                finally { instance.ReleaseMutex(); }
            }
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "Sonder could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void RunWindow(string workspace)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var window = new StudioWindow(workspace))
            Application.Run(window);
    }

    private static Assembly ResolveWebViewAssembly(object sender, ResolveEventArgs args)
    {
        string name = new AssemblyName(args.Name).Name;
        if (name != "Microsoft.Web.WebView2.Core" && name != "Microsoft.Web.WebView2.WinForms")
            return null;
        return Assembly.Load(ReadResource(name + ".dll"));
    }

    internal static byte[] ReadResource(string name)
    {
        using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourcePrefix + name))
        using (var bytes = new MemoryStream())
        {
            if (resource == null) throw new InvalidOperationException("Missing desktop component " + name + ".");
            resource.CopyTo(bytes);
            return bytes.ToArray();
        }
    }

    private static bool HasWorkspace(string path)
    {
        return File.Exists(Path.Combine(path, "app.py")) &&
               File.Exists(Path.Combine(path, "desktop", "backend.py"));
    }

    private static string FindWorkspace()
    {
        for (var folder = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory); folder != null; folder = folder.Parent)
            if (HasWorkspace(folder.FullName)) return folder.FullName;
        var embedded = Encoding.UTF8.GetString(ReadResource("workspace.txt")).Trim().TrimStart('\uFEFF');
        if (!String.IsNullOrWhiteSpace(embedded) && HasWorkspace(embedded)) return embedded;
        throw new DirectoryNotFoundException("Sonder's workspace was moved or is missing. Keep Sonder.exe with the Sonder workspace.");
    }

    private static string WorkspaceKey(string path)
    {
        using (var digest = SHA256.Create())
            return BitConverter.ToString(digest.ComputeHash(Encoding.UTF8.GetBytes(path.ToUpperInvariant())));
    }
}

internal sealed class StudioWindow : Form
{
    private const string ReadyPrefix = "SONDER_PORT=";
    private readonly string workspace;
    private readonly string dataDirectory;
    private readonly string logPath;
    private readonly object logLock = new object();
    private readonly Label status;
    private readonly TaskCompletionSource<int> readyPort = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
    private Process backend;
    private ChildProcessGroup processGroup;
    private WebView2 webView;
    private bool providerBusy;
    private Uri serviceUrl;
    private bool closing;

    internal StudioWindow(string workspace)
    {
        this.workspace = workspace;
        dataDirectory = Path.Combine(workspace, "data");
        logPath = Path.Combine(dataDirectory, "desktop.log");
        Text = "Sonder";
        ClientSize = new Size(1160, 790);
        MinimumSize = new Size(440, 500);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(21, 25, 22);
        ForeColor = Color.FromArgb(224, 231, 218);
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        status = new Label
        {
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 12),
            Padding = new Padding(24),
            Text = "Starting Sonder…"
        };
        Controls.Add(status);
        Shown += OpenStudio;
    }

    protected override void OnHandleCreated(EventArgs args)
    {
        base.OnHandleCreated(args);
        int dark = 1;
        try
        {
            if (DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int)) != 0)
                DwmSetWindowAttribute(Handle, 19, ref dark, sizeof(int));
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    private async void OpenStudio(object sender, EventArgs args)
    {
        try
        {
            Directory.CreateDirectory(dataDirectory);
            File.WriteAllText(logPath, "Starting Sonder desktop.\r\n");
            string loaderFolder = Path.Combine(dataDirectory, "desktop-runtime");
            Directory.CreateDirectory(loaderFolder);
            File.WriteAllBytes(Path.Combine(loaderFolder, "WebView2Loader.dll"), Desktop.ReadResource("WebView2Loader.dll"));
            CoreWebView2Environment.SetLoaderDllFolderPath(loaderFolder);
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(dataDirectory, "desktop-webview"));
            if (closing) return;

            StartBackend();
            if (await Task.WhenAny(readyPort.Task, Task.Delay(TimeSpan.FromSeconds(30))) != readyPort.Task)
                throw new TimeoutException("The local Sonder service did not start within 30 seconds.");
            int port = await readyPort.Task;
            if (closing) return;
            WriteLog("Sonder service is ready on loopback port " + port + ".");

            var url = new Uri("http://127.0.0.1:" + port + "/");
            serviceUrl = url;
            webView = new WebView2
            {
                Dock = DockStyle.Fill,
                DefaultBackgroundColor = BackColor,
                Visible = false
            };
            Controls.Add(webView);
            await webView.EnsureCoreWebView2Async(environment);
            if (closing) return;

            var core = webView.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            core.NavigationStarting += (s, e) =>
            {
                Uri target;
                e.Cancel = !Uri.TryCreate(e.Uri, UriKind.Absolute, out target) ||
                           target.Scheme != url.Scheme || target.Host != url.Host || target.Port != url.Port;
            };
            core.NewWindowRequested += (s, e) => e.Handled = true;
            core.WebMessageReceived += (s, e) =>
            {
                Uri source;
                if (!Uri.TryCreate(e.Source, UriKind.Absolute, out source) || source.GetLeftPart(UriPartial.Authority) != url.GetLeftPart(UriPartial.Authority))
                    return;
                string command;
                try { command = e.TryGetWebMessageAsString(); }
                catch (ArgumentException) { return; }
                const string prefix = "fetch-spotisaver|";
                if (command.StartsWith(prefix, StringComparison.Ordinal))
                    FetchSpotiSaver(command.Substring(prefix.Length));
                else if (command.StartsWith("choose-output|", StringComparison.Ordinal))
                    ChooseOutputFolder(command.Substring("choose-output|".Length));
            };
            core.NavigationCompleted += (s, e) =>
            {
                if (e.IsSuccess)
                {
                    status.Hide();
                    webView.Show();
                    webView.BringToFront();
                    WriteLog("Sonder desktop interface loaded.");
                }
                else if (e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                {
                    ShowError("The desktop window could not connect to Sonder (" + e.WebErrorStatus + ").");
                }
            };
            core.Navigate(url.AbsoluteUri);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            ShowError("Install the Microsoft Edge WebView2 Runtime, then reopen Sonder.");
        }
        catch (Exception exception)
        {
            WriteLog(exception.ToString());
            ShowError(exception.Message);
        }
    }

    private static bool IsSpotiSaver(string address)
    {
        Uri uri;
        return Uri.TryCreate(address, UriKind.Absolute, out uri) && uri.Scheme == "https" &&
               uri.IsDefaultPort && uri.UserInfo.Length == 0 && uri.Host == "spotisaver.net";
    }

    private void ChooseOutputFolder(string current)
    {
        using (var dialog = new FolderBrowserDialog
        {
            Description = "Choose where Sonder saves your song folders.",
            ShowNewFolderButton = true
        })
        {
            if (Directory.Exists(current)) dialog.SelectedPath = current;
            if (dialog.ShowDialog(this) == DialogResult.OK)
                webView.CoreWebView2.PostWebMessageAsString("output-folder|" + dialog.SelectedPath);
        }
    }

    private const string ProviderPage = "https://spotisaver.net/en1";
    private const long AudioSizeLimit = 128L * 1024 * 1024;
    private const string ReadProviderPage = @"(() => {
        const check = document.querySelector('#playlistTurnstileBlock iframe, iframe[title*=""security challenge"" i]');
        const visible = check && check.getBoundingClientRect().width >= 100 && check.getBoundingClientRect().height >= 40;
        const notice = document.getElementById('notification');
        const error = document.querySelector('#loaderError.is-visible');
        const text = ((error && error.textContent) ||
                      (notice && getComputedStyle(notice).opacity !== '0' && notice.textContent) || '');
        if (visible || /security verification|request verification|captcha|verify you are human/i.test(text)) return 'verification';
        if (error || /not found|unavailable|download error|premium required|failed|too many/i.test(text)) return 'unavailable';
        const rows = document.querySelectorAll('#trackList .track-item');
        if (rows.length > 1) return 'multiple';
        return rows.length === 1 && rows[0].querySelector('.btn-download:not([disabled])') ? 'ready' : 'pending';
    })()";

    private void NotifyStudio(string message)
    {
        if (!closing && webView != null && !webView.IsDisposed && webView.CoreWebView2 != null)
            webView.CoreWebView2.PostWebMessageAsString(message);
    }

    private static async Task<T> WaitForProvider<T>(Task<T> task, int seconds, string message)
    {
        if (await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(seconds))) != task)
            throw new TimeoutException(message);
        return await task;
    }

    private async void FetchSpotiSaver(string spotify)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(spotify, @"\Ahttps://open\.spotify\.com/track/[a-zA-Z0-9]{22}\z"))
        {
            NotifyStudio("spotisaver-error|Paste a Spotify track link.");
            return;
        }
        if (providerBusy) return;

        providerBusy = true;
        string path = null;
        bool keepFile = false;
        WebView2 browser = null;
        try
        {
            NotifyStudio("spotisaver-status|Looking up the track in SpotiSaver…");
            var profile = await WaitForProvider(
                CoreWebView2Environment.CreateAsync(null, Path.Combine(dataDirectory, "spotisaver-webview")),
                25, "SpotiSaver could not start.");
            if (closing) return;

            // Keep the provider in a separate WebView with no bridge to the
            // desktop app. Only the local Studio remains on screen.
            browser = new WebView2 { Bounds = new Rectangle(-12000, 0, 900, 650), TabStop = false };
            Controls.Add(browser);
            browser.SendToBack();
            var initialize = browser.EnsureCoreWebView2Async(profile);
            if (await Task.WhenAny(initialize, Task.Delay(25000)) != initialize)
                throw new TimeoutException("SpotiSaver could not open in the background.");
            await initialize;
            if (closing) return;
            var core = browser.CoreWebView2;
            core.IsMuted = true;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.PermissionRequested += (s, e) => e.State = CoreWebView2PermissionState.Deny;
            core.NavigationStarting += (s, e) => e.Cancel = !IsSpotiSaver(e.Uri);
            core.NewWindowRequested += (s, e) => e.Handled = true;

            var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var file = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            bool armed = false;
            core.NavigationCompleted += (s, e) => loaded.TrySetResult(e.IsSuccess);
            core.DownloadStarting += (s, e) =>
            {
                var operation = e.DownloadOperation;
                string name = Path.GetFileName(e.ResultFilePath ?? "");
                if (!armed || path != null || !IsSpotiSaver(core.Source) ||
                    !String.Equals(Path.GetExtension(name), ".mp3", StringComparison.OrdinalIgnoreCase) ||
                    operation.TotalBytesToReceive > AudioSizeLimit)
                {
                    e.Cancel = true;
                    if (armed && path == null) file.TrySetException(new IOException("SpotiSaver did not offer an MP3 under 128 MB."));
                    return;
                }
                var target = Path.Combine(dataDirectory, "spotisaver-temp", Guid.NewGuid().ToString("N") + ".mp3");
                path = target;
                e.ResultFilePath = target;
                e.Handled = true;
                operation.BytesReceivedChanged += (sender, args) =>
                {
                    if (operation.BytesReceived > AudioSizeLimit) operation.Cancel();
                };
                operation.StateChanged += (sender, args) =>
                {
                    if (operation.State == CoreWebView2DownloadState.Completed) file.TrySetResult(name);
                    else if (operation.State == CoreWebView2DownloadState.Interrupted)
                        file.TrySetException(new IOException("SpotiSaver's download was interrupted."));
                };
            };

            core.Navigate(ProviderPage);
            if (!await WaitForProvider(loaded.Task, 30, "SpotiSaver did not open in time."))
                throw new IOException("SpotiSaver did not load. Try again later.");
            if (!IsSpotiSaver(core.Source)) throw new IOException("SpotiSaver did not open as expected.");

            // The URL was reduced to a fixed Spotify host and 22-character ID.
            // Submit the normal page form so its checks and limits still apply.
            string submitted = await core.ExecuteScriptAsync(@"(() => {
                const input = document.getElementById('playlistUrl');
                const form = document.getElementById('playlistForm');
                if (!input || !form || !form.requestSubmit) return false;
                input.value = '" + spotify + @"';
                input.dispatchEvent(new Event('input', {bubbles:true}));
                form.requestSubmit();
                return true;
            })()");
            if (submitted != "true") throw new IOException("SpotiSaver's form was unavailable. Try again later.");

            var lookup = Stopwatch.StartNew();
            while (true)
            {
                string result = await core.ExecuteScriptAsync(ReadProviderPage);
                CheckProviderResult(result);
                if (result == "\"ready\"") break;
                if (lookup.Elapsed.TotalSeconds >= 50) throw new TimeoutException("SpotiSaver did not find this track in time.");
                await Task.Delay(450);
                if (closing) return;
            }

            NotifyStudio("spotisaver-status|Downloading the matched MP3 from SpotiSaver…");
            armed = true;
            string clicked = await core.ExecuteScriptAsync(@"(() => {
                const buttons = document.querySelectorAll('#trackList .track-item .btn-download:not([disabled])');
                if (buttons.length !== 1) return false;
                buttons[0].click();
                return true;
            })()");
            if (clicked != "true") throw new IOException("SpotiSaver's download button was unavailable.");

            var download = Stopwatch.StartNew();
            while (await Task.WhenAny(file.Task, Task.Delay(600)) != file.Task)
            {
                if (closing) return;
                if (path == null) CheckProviderResult(await core.ExecuteScriptAsync(ReadProviderPage));
                if (download.Elapsed.TotalSeconds >= 150) throw new TimeoutException("SpotiSaver did not finish the download in time.");
            }
            string filename = System.Text.RegularExpressions.Regex.Replace(
                await file.Task, @"\s*\(SPOTISAVER\)(?=\.mp3$)", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            NotifyStudio("spotisaver-status|MP3 received. Starting separation…");
            keepFile = true;
            await Task.Run(() => ImportDownloadedAudio(path, filename));
            keepFile = false;
            NotifyStudio("spotisaver-imported");
        }
        catch (Exception exception)
        {
            WriteLog("SpotiSaver download: " + exception.Message);
            if (keepFile)
                NotifyStudio("spotisaver-error|The MP3 downloaded, but Sonder could not import it. Choose the file at " + path);
            else
                NotifyStudio("spotisaver-error|" + exception.Message);
        }
        finally
        {
            if (browser != null) browser.Dispose();
            if (path != null && !keepFile)
            {
                try { File.Delete(path); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            providerBusy = false;
        }
    }

    private static void CheckProviderResult(string result)
    {
        if (result == "\"verification\"") throw new IOException("SpotiSaver requested interactive verification. It did not provide a download.");
        if (result == "\"unavailable\"") throw new IOException("SpotiSaver could not provide this track. Try a different link or retry later.");
        if (result == "\"multiple\"") throw new IOException("SpotiSaver returned multiple tracks. Paste an individual Spotify track link.");
    }

    private void ImportDownloadedAudio(string path, string name)
    {
        var address = new Uri(serviceUrl, "api/audio/import?name=" + Uri.EscapeDataString(name));
        var request = (HttpWebRequest)WebRequest.Create(address);
        request.Method = "POST";
        request.ContentType = "application/octet-stream";
        request.AllowAutoRedirect = false;
        request.AllowWriteStreamBuffering = false;
        request.Proxy = null;
        request.Timeout = 120000;
        using (var input = File.OpenRead(path))
        {
            request.ContentLength = input.Length;
            using (var output = request.GetRequestStream()) input.CopyTo(output);
        }
        using (var response = (HttpWebResponse)request.GetResponse())
        {
            if (response.StatusCode != HttpStatusCode.Accepted) throw new IOException("Sonder did not accept the audio file.");
        }
    }

    private void StartBackend()
    {
        string python = Path.Combine(workspace, ".python310", "python.exe");
        if (!File.Exists(python))
            python = Path.Combine(workspace, ".venv310", "Scripts", "python.exe");
        if (!File.Exists(python))
        {
            string setup = File.Exists(Path.Combine(workspace, "desktop", "installed-runtime.txt"))
                ? "Run Sonder-Setup.exe again to repair the installation."
                : "Run Setup Sonder.cmd if Sonder came in a ZIP, then reopen it.";
            throw new FileNotFoundException("Sonder's Python runtime is missing. " + setup);
        }

        var info = new ProcessStartInfo(python, "-B -X utf8 -m desktop.backend")
        {
            WorkingDirectory = workspace,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        info.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        info.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";
        backend = new Process { StartInfo = info, EnableRaisingEvents = true };
        backend.OutputDataReceived += (sender, args) =>
        {
            int port;
            if (args.Data != null && args.Data.StartsWith(ReadyPrefix, StringComparison.Ordinal) &&
                int.TryParse(args.Data.Substring(ReadyPrefix.Length), out port) && port > 0 && port <= 65535)
                readyPort.TrySetResult(port);
            else
                WriteLog(args.Data);
        };
        backend.ErrorDataReceived += (sender, args) => WriteLog(args.Data);
        backend.Exited += (sender, args) =>
        {
            if (!readyPort.TrySetException(new InvalidOperationException("The local Sonder service exited during startup.")))
            {
                try { BeginInvoke(new Action(() => ShowError("The local Sonder service stopped."))); }
                catch (InvalidOperationException) { }
            }
        };
        if (!backend.Start()) throw new InvalidOperationException("Could not launch the local Sonder service.");
        processGroup = ChildProcessGroup.Attach(backend);
        backend.BeginOutputReadLine();
        backend.BeginErrorReadLine();
    }

    private void WriteLog(string message)
    {
        if (String.IsNullOrEmpty(message)) return;
        try
        {
            lock (logLock) File.AppendAllText(logPath, message + Environment.NewLine, Encoding.UTF8);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void ShowError(string message)
    {
        if (closing) return;
        if (webView != null) webView.Hide();
        status.Text = message + Environment.NewLine + Environment.NewLine + "Details: " + logPath;
        status.Show();
        status.BringToFront();
    }

    protected override void OnFormClosed(FormClosedEventArgs args)
    {
        closing = true;
        try
        {
            if (backend != null && !backend.HasExited)
            {
                backend.StandardInput.Close();
                if (!backend.WaitForExit(2500) && processGroup == null) backend.Kill();
            }
        }
        catch (InvalidOperationException) { }
        catch (IOException) { }
        finally
        {
            if (processGroup != null) processGroup.Dispose();
            if (backend != null) backend.Dispose();
        }
        base.OnFormClosed(args);
    }
}

internal sealed class ChildProcessGroup : IDisposable
{
    private readonly SafeFileHandle handle;

    private ChildProcessGroup(SafeFileHandle handle)
    {
        this.handle = handle;
    }

    internal static ChildProcessGroup Attach(Process process)
    {
        const int extendedLimitInformation = 9;
        const uint killOnClose = 0x2000;
        SafeFileHandle handle = CreateJobObject(IntPtr.Zero, null);
        var limits = new ExtendedLimitInformation
        {
            BasicLimitInformation = new BasicLimitInformation { LimitFlags = killOnClose }
        };
        if (handle.IsInvalid ||
            !SetInformationJobObject(handle, extendedLimitInformation, ref limits, (uint)Marshal.SizeOf(limits)) ||
            !AssignProcessToJobObject(handle, process.Handle))
        {
            handle.Dispose();
            return null;
        }
        return new ChildProcessGroup(handle);
    }

    public void Dispose()
    {
        handle.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass, ref ExtendedLimitInformation information, uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
}
