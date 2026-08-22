using System.ComponentModel;
using System.Windows.Input;

namespace PoolarisNodeGUI.ViewModels;

public sealed class MainViewModel : ViewModelBase
{
    private readonly DashboardViewModel _dashboard = new();
    private readonly NodeLauncherViewModel _launcher = new();
    private readonly PeersViewModel _peers = new();
    private readonly PerformanceViewModel _performance = new();
    private readonly LogsViewModel _logs = new();
    private readonly SettingsViewModel _settings = new();

    private ViewModelBase _currentPage;
    private string _currentPageTitle = "Dashboard";
    private string _nodeStatus = "NODE STOPPED";

    public MainViewModel()
    {
        _currentPage = _dashboard;
        _launcher.PropertyChanged += LauncherOnPropertyChanged;
        NavigateCommand = new RelayCommand(Navigate);
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
            NodeStatus = _launcher.ProcessStateLabel;
    }
}
