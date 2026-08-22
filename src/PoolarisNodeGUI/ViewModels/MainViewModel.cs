using System.Windows.Input;

namespace PoolarisNodeGUI.ViewModels;

public sealed class MainViewModel : ViewModelBase
{
    private ViewModelBase _currentPage;
    private string _currentPageTitle = "Dashboard";
    private string _nodeStatus = "NODE STOPPED";

    public MainViewModel()
    {
        _currentPage = new DashboardViewModel();
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
        set => SetProperty(ref _nodeStatus, value);
    }

    public ICommand NavigateCommand { get; }

    private void Navigate(object? parameter)
    {
        var key = parameter as string ?? "Dashboard";
        (CurrentPage, CurrentPageTitle) = key switch
        {
            "NodeLauncher" => (new NodeLauncherViewModel(), "Node Launcher"),
            "Peers" => (new PeersViewModel(), "Peers"),
            "Performance" => (new PerformanceViewModel(), "Performance"),
            "Logs" => (new LogsViewModel(), "Logs"),
            "Settings" => (new SettingsViewModel(), "Settings"),
            _ => (new DashboardViewModel(), "Dashboard")
        };
    }
}
