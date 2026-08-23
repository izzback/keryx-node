using System.ComponentModel;
using System.Windows.Input;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class MainViewModel : ViewModelBase, IDisposable
{
    private readonly RuntimeNodeSession _runtimeSession;
    private readonly RuntimeRpcMonitor _rpcMonitor;
    private readonly DashboardViewModel _dashboard;
    private readonly NodeLauncherViewModel _launcher;
    private readonly PeersViewModel _peers;
    private readonly PerformanceViewModel _performance;
    private readonly LogsViewModel _logs;
    private readonly SettingsViewModel _settings;

    private ViewModelBase _currentPage;
    private string _currentPageTitle = "Dashboard";
    private string _nodeStatus = "NODE STOPPED";
    private bool _disposed;

    public MainViewModel()
    {
        _runtimeSession = new RuntimeNodeSession();
        _rpcMonitor = new RuntimeRpcMonitor(_runtimeSession);
        _dashboard = new DashboardViewModel(_runtimeSession);
        _launcher = new NodeLauncherViewModel(_runtimeSession);
        _peers = new PeersViewModel(_runtimeSession);
        _performance = new PerformanceViewModel();
        _logs = new LogsViewModel();
        _settings = new SettingsViewModel();

        _currentPage = _dashboard;
        _launcher.PropertyChanged += LauncherOnPropertyChanged;
        _runtimeSession.PropertyChanged += RuntimeSessionOnPropertyChanged;
        NavigateCommand = new RelayCommand(Navigate);
        RefreshNodeStatus();
    }

    public ViewModelBase CurrentPage
    {
        get => _currentPage;
        private set => SetProperty(ref _currentPage, value);
    }

    public string CurrentPageTitle
    {
        get => _currentPageTitle;
        private set => SetProperty(ref _currentPageTitle, value);
    }

    public string NodeStatus
    {
        get => _nodeStatus;
        private set => SetProperty(ref _nodeStatus, value);
    }

    public ICommand NavigateCommand { get; }

    private void Navigate(object? parameter)
    {
        var key = parameter as string ?? "Dashboard";
        (ViewModelBase Page, string Title) target = key switch
        {
            "NodeLauncher" => (_launcher, "Node Launcher"),
            "Peers" => (_peers, "Peers"),
            "Performance" => (_performance, "Performance"),
            "Logs" => (_logs, "Logs"),
            "Settings" => (_settings, "Settings"),
            _ => (_dashboard, "Dashboard")
        };

        CurrentPage = target.Page;
        CurrentPageTitle = target.Title;
    }

    private void LauncherOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NodeLauncherViewModel.ProcessStateLabel))
            RefreshNodeStatus();
    }

    private void RuntimeSessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.IsAttached)
            or nameof(RuntimeNodeSession.RpcConnected)
            or nameof(RuntimeNodeSession.RpcStatus))
        {
            RefreshNodeStatus();
        }
    }

    private void RefreshNodeStatus()
    {
        NodeStatus = _runtimeSession.IsAttached
            ? _runtimeSession.RpcConnected ? "NODE RUNNING" : "NODE ATTACHED"
            : _launcher.ProcessStateLabel;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _launcher.PropertyChanged -= LauncherOnPropertyChanged;
        _runtimeSession.PropertyChanged -= RuntimeSessionOnPropertyChanged;
        _rpcMonitor.Dispose();
        _dashboard.Dispose();
        _peers.Dispose();
    }
}
