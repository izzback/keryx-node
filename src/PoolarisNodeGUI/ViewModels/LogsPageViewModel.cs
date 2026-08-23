using System.ComponentModel;
using System.Windows.Input;
using System.Windows.Threading;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class LogsPageViewModel : ViewModelBase, IDisposable
{
    private readonly NodeLauncherViewModel _launcher;
    private readonly DispatcherTimer _timer;
    private string _activeLogFile = "—";
    private string _logText = string.Empty;
    private string _status = "Waiting for Keryx log discovery...";
    private bool _autoRefresh = true;
    private bool _disposed;

    public LogsPageViewModel(NodeLauncherViewModel launcher)
    {
        _launcher = launcher;
        _launcher.PropertyChanged += LauncherOnPropertyChanged;

        RefreshCommand = new RelayCommand(_ => Refresh());
        ClearViewCommand = new RelayCommand(_ => ClearView());

        _timer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _timer.Tick += TimerOnTick;
        _timer.Start();
        Refresh();
    }

    public ICommand RefreshCommand { get; }
    public ICommand ClearViewCommand { get; }

    public string LogDirectory => KeryxPathResolver.ResolveDefaultLogPath(_launcher.AppDirectory, _launcher.IsTestnet);

    public string ActiveLogFile
    {
        get => _activeLogFile;
        private set => SetProperty(ref _activeLogFile, value);
    }

    public string LogText
    {
        get => _logText;
        private set => SetProperty(ref _logText, value);
    }

    public string Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    public bool AutoRefresh
    {
        get => _autoRefresh;
        set
        {
            if (!SetProperty(ref _autoRefresh, value))
                return;

            if (value)
            {
                _timer.Start();
                Refresh();
            }
            else
            {
                _timer.Stop();
            }
        }
    }

    public bool LogFilesDisabled => _launcher.DisableLogFiles;

    private void TimerOnTick(object? sender, EventArgs e)
    {
        if (AutoRefresh)
            Refresh();
    }

    private void LauncherOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NodeLauncherViewModel.AppDirectory)
            or nameof(NodeLauncherViewModel.IsTestnet)
            or nameof(NodeLauncherViewModel.DisableLogFiles))
        {
            OnPropertyChanged(nameof(LogDirectory));
            OnPropertyChanged(nameof(LogFilesDisabled));
            Refresh();
        }
    }

    private void Refresh()
    {
        if (_launcher.DisableLogFiles)
        {
            ActiveLogFile = "—";
            LogText = string.Empty;
            Status = "Les fichiers de logs Keryx sont désactivés dans Node Launcher.";
            return;
        }

        var result = KeryxLogTailReader.ReadNewest(LogDirectory);
        ActiveLogFile = result.ActiveFile ?? "—";
        LogText = result.Text;
        Status = result.Status;
    }

    private void ClearView()
    {
        LogText = string.Empty;
        Status = "Vue effacée uniquement. Aucun fichier Keryx n'a été supprimé.";
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;
        _timer.Stop();
        _timer.Tick -= TimerOnTick;
        _launcher.PropertyChanged -= LauncherOnPropertyChanged;
    }
}
