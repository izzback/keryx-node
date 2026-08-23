using System.ComponentModel;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class SettingsPageViewModel : ViewModelBase, IDisposable
{
    private readonly NodeLauncherViewModel _launcher;
    private readonly RuntimeNodeSession _session;
    private bool _disposed;

    public SettingsPageViewModel(NodeLauncherViewModel launcher, RuntimeNodeSession session)
    {
        _launcher = launcher;
        _session = session;
        _launcher.PropertyChanged += LauncherOnPropertyChanged;
        _session.PropertyChanged += SessionOnPropertyChanged;
    }

    public string NodeExecutable
    {
        get => _launcher.NodeExecutable;
        set
        {
            if (string.Equals(_launcher.NodeExecutable, value, StringComparison.Ordinal)) return;
            _launcher.NodeExecutable = value;
            OnPropertyChanged();
        }
    }

    public string AppDirectory
    {
        get => _launcher.AppDirectory;
        set
        {
            if (string.Equals(_launcher.AppDirectory, value, StringComparison.Ordinal)) return;
            _launcher.AppDirectory = value;
            OnPropertyChanged();
            RaiseResolvedPaths();
        }
    }

    public bool IsTestnet
    {
        get => _launcher.IsTestnet;
        set
        {
            if (_launcher.IsTestnet == value) return;
            _launcher.IsTestnet = value;
            OnPropertyChanged();
            RaiseResolvedPaths();
        }
    }

    public bool UtxoIndex
    {
        get => _launcher.UtxoIndex;
        set
        {
            if (_launcher.UtxoIndex == value) return;
            _launcher.UtxoIndex = value;
            OnPropertyChanged();
        }
    }

    public bool EnableGrpc
    {
        get => _launcher.EnableGrpc;
        set
        {
            if (_launcher.EnableGrpc == value) return;
            _launcher.EnableGrpc = value;
            OnPropertyChanged();
        }
    }

    public int GrpcPort
    {
        get => _launcher.GrpcPort;
        set
        {
            if (_launcher.GrpcPort == value) return;
            _launcher.GrpcPort = value;
            OnPropertyChanged();
        }
    }

    public int OutboundPeers
    {
        get => _launcher.OutboundPeers;
        set
        {
            if (_launcher.OutboundPeers == value) return;
            _launcher.OutboundPeers = value;
            OnPropertyChanged();
        }
    }

    public int MaxInboundPeers
    {
        get => _launcher.MaxInboundPeers;
        set
        {
            if (_launcher.MaxInboundPeers == value) return;
            _launcher.MaxInboundPeers = value;
            OnPropertyChanged();
        }
    }

    public int AsyncThreads
    {
        get => _launcher.AsyncThreads;
        set
        {
            if (_launcher.AsyncThreads == value) return;
            _launcher.AsyncThreads = value;
            OnPropertyChanged();
        }
    }

    public double RamScale
    {
        get => _launcher.RamScale;
        set
        {
            if (Math.Abs(_launcher.RamScale - value) < 0.0001) return;
            _launcher.RamScale = value;
            OnPropertyChanged();
        }
    }

    public int RocksDbCacheSizeMb
    {
        get => _launcher.RocksDbCacheSizeMb;
        set
        {
            if (_launcher.RocksDbCacheSizeMb == value) return;
            _launcher.RocksDbCacheSizeMb = value;
            OnPropertyChanged();
        }
    }

    public string LogLevel
    {
        get => _launcher.LogLevel;
        set
        {
            if (string.Equals(_launcher.LogLevel, value, StringComparison.OrdinalIgnoreCase)) return;
            _launcher.LogLevel = value;
            OnPropertyChanged();
        }
    }

    public IReadOnlyList<string> LogLevels => _launcher.LogLevels;

    public string ResolvedDatabasePath => KeryxPathResolver.ResolveDatabasePath(_launcher.AppDirectory, _launcher.IsTestnet);
    public string ResolvedLogDirectory => KeryxPathResolver.ResolveDefaultLogPath(_launcher.AppDirectory, _launcher.IsTestnet);
    public string UiDiagnosticsLogPath => UiErrorLog.LogPath;
    public string AttachedNode => _session.AttachedNodeLabel;
    public string RpcEndpoint => _session.RpcEndpointDisplay;
    public string RpcStatus => _session.RpcStatus;

    private void LauncherOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(NodeLauncherViewModel.NodeExecutable)) OnPropertyChanged(nameof(NodeExecutable));
        if (e.PropertyName is nameof(NodeLauncherViewModel.AppDirectory))
        {
            OnPropertyChanged(nameof(AppDirectory));
            RaiseResolvedPaths();
        }
        if (e.PropertyName is nameof(NodeLauncherViewModel.IsTestnet))
        {
            OnPropertyChanged(nameof(IsTestnet));
            RaiseResolvedPaths();
        }
        if (e.PropertyName is nameof(NodeLauncherViewModel.UtxoIndex)) OnPropertyChanged(nameof(UtxoIndex));
        if (e.PropertyName is nameof(NodeLauncherViewModel.EnableGrpc)) OnPropertyChanged(nameof(EnableGrpc));
        if (e.PropertyName is nameof(NodeLauncherViewModel.GrpcPort)) OnPropertyChanged(nameof(GrpcPort));
        if (e.PropertyName is nameof(NodeLauncherViewModel.OutboundPeers)) OnPropertyChanged(nameof(OutboundPeers));
        if (e.PropertyName is nameof(NodeLauncherViewModel.MaxInboundPeers)) OnPropertyChanged(nameof(MaxInboundPeers));
        if (e.PropertyName is nameof(NodeLauncherViewModel.AsyncThreads)) OnPropertyChanged(nameof(AsyncThreads));
        if (e.PropertyName is nameof(NodeLauncherViewModel.RamScale)) OnPropertyChanged(nameof(RamScale));
        if (e.PropertyName is nameof(NodeLauncherViewModel.RocksDbCacheSizeMb)) OnPropertyChanged(nameof(RocksDbCacheSizeMb));
        if (e.PropertyName is nameof(NodeLauncherViewModel.LogLevel)) OnPropertyChanged(nameof(LogLevel));
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.AttachedNodeLabel)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcStatus)
            or nameof(RuntimeNodeSession.RpcEndpointVerified))
        {
            OnPropertyChanged(nameof(AttachedNode));
            OnPropertyChanged(nameof(RpcEndpoint));
            OnPropertyChanged(nameof(RpcStatus));
        }
    }

    private void RaiseResolvedPaths()
    {
        OnPropertyChanged(nameof(ResolvedDatabasePath));
        OnPropertyChanged(nameof(ResolvedLogDirectory));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _launcher.PropertyChanged -= LauncherOnPropertyChanged;
        _session.PropertyChanged -= SessionOnPropertyChanged;
    }
}
