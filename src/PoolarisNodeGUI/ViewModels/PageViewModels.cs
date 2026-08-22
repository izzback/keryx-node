using System.ComponentModel;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class DashboardViewModel : ViewModelBase
{
    private readonly RuntimeNodeSession _session;

    public DashboardViewModel() : this(new RuntimeNodeSession()) { }

    public DashboardViewModel(RuntimeNodeSession session)
    {
        _session = session;
        _session.PropertyChanged += SessionOnPropertyChanged;
    }

    public string NodeLabel => _session.AttachedNodeLabel;
    public string NodeExecutable => _session.AttachedNode?.ExecutablePath ?? "—";
    public string NodePid => _session.AttachedPid;
    public string NodeStarted => _session.AttachedNode?.StartedDisplay ?? "—";
    public string NodeUptime
    {
        get
        {
            var started = _session.AttachedNode?.StartTime;
            if (!started.HasValue) return "—";
            var uptime = DateTime.Now - started.Value;
            if (uptime < TimeSpan.Zero) return "—";
            return uptime.TotalDays >= 1
                ? $"{(int)uptime.TotalDays}d {uptime:hh\:mm\:ss}"
                : uptime.ToString("hh\:mm\:ss");
        }
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.AttachedNodeLabel)
            or nameof(RuntimeNodeSession.AttachedPid)
            or nameof(RuntimeNodeSession.IsAttached))
        {
            OnPropertyChanged(nameof(NodeLabel));
            OnPropertyChanged(nameof(NodeExecutable));
            OnPropertyChanged(nameof(NodePid));
            OnPropertyChanged(nameof(NodeStarted));
            OnPropertyChanged(nameof(NodeUptime));
        }
    }
}

public sealed class PeersViewModel : ViewModelBase { }
public sealed class PerformanceViewModel : ViewModelBase { }
public sealed class LogsViewModel : ViewModelBase { }
public sealed class SettingsViewModel : ViewModelBase { }
