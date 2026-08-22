using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Poolaris.NodeGui.Models;
using Poolaris.NodeGui.Services;

namespace Poolaris.NodeGui;

public partial class MainWindow : Window
{
    private const double NetworkBlocksPerSecond = 10.0;

    private readonly NodeProcessService _processService = new();
    private readonly SettingsService _settingsService = new();
    private readonly NodeUpdateService _updateService = new();
    private readonly KeryxLogService _logService = new();
    private readonly NodeMonitorService _monitorService;
    private readonly DispatcherTimer _timer;

    private long? _initialEstimatedBlocksRemaining;
    private NodeReleaseInfo? _availableRelease;

    public MainWindow()
    {
        InitializeComponent();
        _monitorService = new NodeMonitorService(_processService);

        ApplyOptionsToForm(_settingsService.Load());
        RefreshGeneratedCommand();

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => RefreshDashboard();
        _timer.Start();

        RefreshDashboard();
    }

    private NodeLaunchOptions ReadOptionsFromForm()
    {
        static int ReadInt(TextBox box, int fallback) => int.TryParse(box.Text, out var value) ? value : fallback;
        static double ReadDouble(TextBox box, double fallback) => double.TryParse(box.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : fallback;

        var logLevel = (LogLevelCombo.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "info";
        var acceptInbound = InboundCheck.IsChecked == true;

        return new NodeLaunchOptions
        {
            NodeExecutable = ExecutableBox.Text.Trim(),
            DataDirectory = DataDirectoryBox.Text.Trim(),
            Testnet = TestnetRadio.IsChecked == true,
            UtxoIndex = UtxoIndexCheck.IsChecked == true,
            AcceptInbound = acceptInbound,
            EnableGrpc = GrpcCheck.IsChecked == true,
            GrpcPort = ReadInt(GrpcPortBox, 22110),
            EnableWrpcJson = JsonCheck.IsChecked == true,
            WrpcJsonPort = ReadInt(JsonPortBox, 24110),
            EnableWrpcBorsh = BorshCheck.IsChecked == true,
            WrpcBorshPort = ReadInt(BorshPortBox, 23110),
            OutboundPeers = Math.Max(0, ReadInt(OutboundBox, 24)),
            MaxInboundPeers = acceptInbound ? Math.Max(0, ReadInt(InboundBox, 128)) : 0,
            AsyncThreads = Math.Max(1, ReadInt(ThreadsBox, Environment.ProcessorCount)),
            RamScale = Math.Max(0.1, ReadDouble(RamScaleBox, 4.0)),
            RocksDbCacheMiB = Math.Max(128, ReadInt(CacheBox, 8192)),
            RocksDbPreset = "default",
            LogLevel = logLevel,
            EnableIbdPerf = IbdPerfCheck.IsChecked == true
        };
    }

    private void ApplyOptionsToForm(NodeLaunchOptions options)
    {
        ExecutableBox.Text = options.NodeExecutable;
        DataDirectoryBox.Text = options.DataDirectory;
        MainnetRadio.IsChecked = !options.Testnet;
        TestnetRadio.IsChecked = options.Testnet;
        UtxoIndexCheck.IsChecked = options.UtxoIndex;
        InboundCheck.IsChecked = options.AcceptInbound;
        IbdPerfCheck.IsChecked = options.EnableIbdPerf;
        GrpcCheck.IsChecked = options.EnableGrpc;
        GrpcPortBox.Text = options.GrpcPort.ToString(CultureInfo.InvariantCulture);
        JsonCheck.IsChecked = options.EnableWrpcJson;
        JsonPortBox.Text = options.WrpcJsonPort.ToString(CultureInfo.InvariantCulture);
        BorshCheck.IsChecked = options.EnableWrpcBorsh;
        BorshPortBox.Text = options.WrpcBorshPort.ToString(CultureInfo.InvariantCulture);
        OutboundBox.Text = options.OutboundPeers.ToString(CultureInfo.InvariantCulture);
        InboundBox.Text = options.MaxInboundPeers.ToString(CultureInfo.InvariantCulture);
        ThreadsBox.Text = options.AsyncThreads.ToString(CultureInfo.InvariantCulture);
        RamScaleBox.Text = options.RamScale.ToString(CultureInfo.InvariantCulture);
        CacheBox.Text = options.RocksDbCacheMiB.ToString(CultureInfo.InvariantCulture);

        foreach (var item in LogLevelCombo.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Content?.ToString(), options.LogLevel, StringComparison.OrdinalIgnoreCase))
            {
                LogLevelCombo.SelectedItem = item;
                break;
            }
        }
    }

    private void RefreshGeneratedCommand()
    {
        try
        {
            var options = ReadOptionsFromForm();
            GeneratedCommandBox.Text = $"\"{options.NodeExecutable}\" {_processService.BuildArguments(options)}";
        }
        catch
        {
            GeneratedCommandBox.Text = "Waiting for valid launcher options...";
        }
    }

    private void RefreshDashboard()
    {
        RefreshGeneratedCommand();

        var options = ReadOptionsFromForm();
        var process = _monitorService.Sample();

        HeaderStatusText.Text = process.Running ? "● NODE RUNNING" : "● NODE STOPPED";
        HeaderStatusText.Foreground = process.Running ? (System.Windows.Media.Brush)FindResource("GreenBrush") : System.Windows.Media.Brushes.IndianRed;
        SidebarPid.Text = process.Running ? $"PID: {process.ProcessId}" : "PID: -";
        SidebarUptime.Text = process.Running ? $"Uptime: {FormatDuration(process.Uptime)}" : "Uptime: -";
        CpuText.Text = process.Running ? $"{process.CpuPercent:F1}%" : "-";
        RamText.Text = process.Running ? $"{process.WorkingSetBytes / 1024d / 1024d / 1024d:F2} GB" : "-";
        ThreadsText.Text = process.Running ? process.ThreadCount.ToString("N0") : "-";
        FooterText.Text = process.Running
            ? $"Node is running  |  PID {process.ProcessId}  |  Uptime {FormatDuration(process.Uptime)}"
            : "Node is stopped";

        var installed = _updateService.GetInstalledVersion(options.NodeExecutable);
        SidebarVersion.Text = installed is null ? "Version: unknown" : $"Version: {installed}";

        var log = _logService.Read(options.DataDirectory);
        LogPreviewBox.Text = log.Tail.Count == 0 ? "No Keryx log detected yet." : string.Join(Environment.NewLine, log.Tail);
        if (log.Tail.Count > 0)
        {
            LogPreviewBox.CaretIndex = LogPreviewBox.Text.Length;
            LogPreviewBox.ScrollToEnd();
        }

        BlocksPerSecondText.Text = log.BlocksPerSecond > 0 ? $"{log.BlocksPerSecond:F1}" : "-";
        IbdPerfText.Text = log.LatestIbdPerfLine ?? "Waiting for IBD-PERF log samples...";

        if (log.LastBlockTimestamp is { } localBlock)
        {
            var lagSeconds = Math.Max(0, (DateTimeOffset.Now - localBlock).TotalSeconds);
            var remaining = (long)Math.Ceiling(lagSeconds * NetworkBlocksPerSecond);
            BlocksRemainingText.Text = remaining.ToString("N0");

            if (_initialEstimatedBlocksRemaining is null || remaining > _initialEstimatedBlocksRemaining.Value * 1.10)
                _initialEstimatedBlocksRemaining = Math.Max(remaining, 1);

            var baseline = Math.Max(1, _initialEstimatedBlocksRemaining ?? remaining);
            var progress = Math.Clamp(100.0 * (1.0 - remaining / (double)baseline), 0, 100);
            if (remaining <= NetworkBlocksPerSecond * 3) progress = 100;
            SyncProgressBar.Value = progress;
            SyncPercentText.Text = $"{progress:F1}% catch-up";

            var catchupBps = log.BlocksPerSecond - NetworkBlocksPerSecond;
            if (catchupBps > 0.1)
            {
                var eta = TimeSpan.FromSeconds(remaining / catchupBps);
                EtaText.Text = FormatDuration(eta);
            }
            else
            {
                EtaText.Text = "waiting";
            }
        }
        else
        {
            BlocksRemainingText.Text = "-";
            EtaText.Text = "-";
            SyncPercentText.Text = "Waiting for block timestamp";
        }

        StartButton.IsEnabled = !process.Running;
        StopButton.IsEnabled = process.Running;
    }

    private async void StartNode_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var options = ReadOptionsFromForm();
            _settingsService.Save(options);
            _processService.Start(options);
            _initialEstimatedBlocksRemaining = null;
            RefreshDashboard();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Unable to start Keryx node", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void StopNode_Click(object sender, RoutedEventArgs e)
    {
        var answer = MessageBox.Show(
            this,
            "Poolaris will request the node to stop. If it does not stop within 15 seconds, this initial build can force-close it. Continue?",
            "Stop Keryx node",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (answer != MessageBoxResult.Yes)
            return;

        try
        {
            await _processService.StopAsync(TimeSpan.FromSeconds(15));
            RefreshDashboard();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Unable to stop node", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void CheckUpdates_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            UpdateButton.IsEnabled = false;
            UpdateStatusText.Text = "Checking official Keryx releases...";

            var options = ReadOptionsFromForm();
            var latest = await _updateService.GetLatestReleaseAsync();
            _availableRelease = latest;
            var installed = _updateService.GetInstalledVersion(options.NodeExecutable);

            if (!NodeUpdateService.VersionsDiffer(installed, latest.Version))
            {
                UpdateStatusText.Text = $"Latest version installed ({latest.Tag})";
                return;
            }

            UpdateStatusText.Text = $"Update available: {latest.Tag}";
            var running = _processService.FindRunningNode() is { HasExited: false };
            if (running)
            {
                MessageBox.Show(
                    this,
                    $"Keryx {latest.Tag} is available. Stop the node first; the update button can then install it with an automatic executable backup.",
                    "Node update available",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var answer = MessageBox.Show(
                this,
                $"Install Keryx {latest.Tag}?\n\nAsset: {latest.AssetName}\n\nThe current keryxd.exe will be backed up before replacement.",
                "Install Keryx update",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (answer != MessageBoxResult.Yes)
                return;

            UpdateStatusText.Text = $"Downloading {latest.Tag}...";
            var backup = await _updateService.InstallAsync(latest, options.NodeExecutable, nodeIsRunning: false);
            UpdateStatusText.Text = $"Updated to {latest.Tag}";
            MessageBox.Show(this, $"Update installed successfully.\nBackup: {backup}", "Keryx updated", MessageBoxButton.OK, MessageBoxImage.Information);
            RefreshDashboard();
        }
        catch (Exception ex)
        {
            UpdateStatusText.Text = "Update check failed";
            MessageBox.Show(this, ex.Message, "Keryx update", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            UpdateButton.IsEnabled = true;
        }
    }

    private void BrowseExecutable_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Filter = "Keryx node (keryxd.exe)|keryxd.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*",
            CheckFileExists = true
        };

        if (dialog.ShowDialog(this) == true)
        {
            ExecutableBox.Text = dialog.FileName;
            RefreshGeneratedCommand();
        }
    }

    private void BrowseData_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select the Keryx data directory",
            InitialDirectory = Directory.Exists(DataDirectoryBox.Text) ? DataDirectoryBox.Text : null
        };

        if (dialog.ShowDialog(this) == true)
        {
            DataDirectoryBox.Text = dialog.FolderName;
            RefreshGeneratedCommand();
        }
    }

    private static string FormatDuration(TimeSpan value)
    {
        if (value.TotalDays >= 1) return $"{(int)value.TotalDays}d {value.Hours:00}h {value.Minutes:00}m";
        if (value.TotalHours >= 1) return $"{(int)value.TotalHours}h {value.Minutes:00}m {value.Seconds:00}s";
        if (value.TotalMinutes >= 1) return $"{(int)value.TotalMinutes}m {value.Seconds:00}s";
        return $"{Math.Max(0, (int)value.TotalSeconds)}s";
    }
}
