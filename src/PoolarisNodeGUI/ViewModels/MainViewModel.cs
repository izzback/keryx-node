using System.ComponentModel;
using System.Windows.Input;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class MainViewModel : ViewModelBase
{
    private readonly RuntimeNodeSession _runtimeSession;
    private readonly DashboardViewModel _dashboard;
    private readonly NodeLauncherViewModel _launcher;
    private readonly PeersViewModel _peers;
    private readonly PerformanceViewModel _performance;
    private readonly LogsViewModel _logs;
    private readonly SettingsViewModel _settings;

    private ViewModelBase _currentPage;
    private string _currentPageTitle = "Dashboard";
    private string _nodeStatus = "NODE STOPPED";

    public MainViewModel()
    {
        _runtimeSession = new RuntimeNodeSession();
        _dashboard = new DashboardViewModel(_runtimeSession);
        _launcher = new NodeLauncherViewModel(_runtimeSession);
        _peers = new PeersViewModel();
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
        (CurrentPage, CurrentPageTitle) = key switch
        {
            "NodeLauncher" => (_launcher, "Node Launcher"),
            "Peers" => (_peers, "Peers"),
            "Performance" => (_performance, "Performance"),
            "Logs" => (_logs, "Logs"),
            "Settings" => (_settings, "Settings"),
            _ => (_dashboard, "Dashboard")
        };
    }

    private void LauncherOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NodeLauncherViewModel.ProcessStateLabel))
            RefreshNodeStatus();
    }

    private void RuntimeSessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode) or nameof(RuntimeNodeSession.IsAttached))
            RefreshNodeStatus();
    }

    private void RefreshNodeStatus()
    {
        NodeStatus = _runtimeSession.IsAttached
            ? "NODE RUNNING"
            : _launcher.ProcessStateLabel;
    }
}
