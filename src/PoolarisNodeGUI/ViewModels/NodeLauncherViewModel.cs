using System.ComponentModel;
using System.Windows.Input;
using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class NodeLauncherViewModel : ViewModelBase
{
    private readonly KeryxArgumentBuilder _argumentBuilder = new();
    private readonly KeryxProcessService _processService;

    private string _nodeExecutable = string.Empty;
    private string _appDirectory = string.Empty;
    private bool _isTestnet;
    private bool _utxoIndex = true;
    private bool _acceptInboundConnections = true;
    private bool _dnsPeerDiscovery = true;
    private bool _upnp = true;
    private bool _enableGrpc = true;
    private bool _enableWrpcJson = true;
    private bool _enableWrpcBorsh = true;
    private int _grpcPort = 22110;
    private int _wrpcJsonPort = 24110;
    private int _wrpcBorshPort = 23110;
    private int _outboundPeers = 16;
    private int _maxInboundPeers = 64;
    private int _asyncThreads = Math.Max(1, Environment.ProcessorCount);
    private double _ramScale = 4.0;
    private int _rocksDbCacheSizeMb = 4096;
    private string _rocksDbPreset = "default";
    private string _logLevel = "info";
    private bool _archival;
    private bool _unsafeRpc;
    private bool _enableUnsyncedMining;
    private bool _disableLogFiles;
    private bool _rocksDbNoBlobFiles;
    private NodeProcessState _processState = NodeProcessState.Stopped;
    private int? _processId;
    private string _statusMessage = "Ready";
    private string _lastError = string.Empty;

    public NodeLauncherViewModel() : this(new RuntimeNodeSession()) { }

    public NodeLauncherViewModel(RuntimeNodeSession runtimeSession)
    {
        _processService = new KeryxProcessService(_argumentBuilder);
        ProcessControl = new ProcessControlViewModel(runtimeSession);
        ProcessControl.PropertyChanged += ProcessControlOnPropertyChanged;

        var start = new AsyncRelayCommand(StartAsync, () => ProcessState is NodeProcessState.Stopped or NodeProcessState.Failed);
        var stop = new AsyncRelayCommand(StopAsync, () => ProcessState == NodeProcessState.Running);
        var restart = new AsyncRelayCommand(RestartAsync, () => ProcessState == NodeProcessState.Running);
        start.ExecutionFailed += OnCommandFailed;
        stop.ExecutionFailed += OnCommandFailed;
        restart.ExecutionFailed += OnCommandFailed;

        StartCommand = start;
        StopCommand = stop;
        RestartCommand = restart;
    }

    public ProcessControlViewModel ProcessControl { get; }

    public string NodeExecutable { get => _nodeExecutable; set { if (SetProperty(ref _nodeExecutable, value)) RefreshComputed(); } }
    public string AppDirectory { get => _appDirectory; set { if (SetProperty(ref _appDirectory, value)) RefreshComputed(); } }
    public bool IsTestnet { get => _isTestnet; set { if (SetProperty(ref _isTestnet, value)) { ApplyNetworkPorts(); RefreshComputed(); } } }
    public bool UtxoIndex { get => _utxoIndex; set { if (SetProperty(ref _utxoIndex, value)) RefreshComputed(); } }
    public bool AcceptInboundConnections { get => _acceptInboundConnections; set { if (SetProperty(ref _acceptInboundConnections, value)) RefreshComputed(); } }
    public bool DnsPeerDiscovery { get => _dnsPeerDiscovery; set { if (SetProperty(ref _dnsPeerDiscovery, value)) RefreshComputed(); } }
    public bool Upnp { get => _upnp; set { if (SetProperty(ref _upnp, value)) RefreshComputed(); } }
    public bool EnableGrpc { get => _enableGrpc; set { if (SetProperty(ref _enableGrpc, value)) RefreshComputed(); } }
    public bool EnableWrpcJson { get => _enableWrpcJson; set { if (SetProperty(ref _enableWrpcJson, value)) RefreshComputed(); } }
    public bool EnableWrpcBorsh { get => _enableWrpcBorsh; set { if (SetProperty(ref _enableWrpcBorsh, value)) RefreshComputed(); } }
    public int GrpcPort { get => _grpcPort; set { if (SetProperty(ref _grpcPort, value)) RefreshComputed(); } }
    public int WrpcJsonPort { get => _wrpcJsonPort; set { if (SetProperty(ref _wrpcJsonPort, value)) RefreshComputed(); } }
    public int WrpcBorshPort { get => _wrpcBorshPort; set { if (SetProperty(ref _wrpcBorshPort, value)) RefreshComputed(); } }
    public int OutboundPeers { get => _outboundPeers; set { if (SetProperty(ref _outboundPeers, value)) RefreshComputed(); } }
    public int MaxInboundPeers { get => _maxInboundPeers; set { if (SetProperty(ref _maxInboundPeers, value)) RefreshComputed(); } }
    public int AsyncThreads { get => _asyncThreads; set { if (SetProperty(ref _asyncThreads, value)) RefreshComputed(); } }
    public double RamScale { get => _ramScale; set { if (SetProperty(ref _ramScale, value)) RefreshComputed(); } }
    public int RocksDbCacheSizeMb { get => _rocksDbCacheSizeMb; set { if (SetProperty(ref _rocksDbCacheSizeMb, value)) RefreshComputed(); } }
    public string RocksDbPreset { get => _rocksDbPreset; set { if (SetProperty(ref _rocksDbPreset, value)) RefreshComputed(); } }
    public string LogLevel { get => _logLevel; set { if (SetProperty(ref _logLevel, value)) RefreshComputed(); } }
    public bool Archival { get => _archival; set { if (SetProperty(ref _archival, value)) RefreshComputed(); } }
    public bool UnsafeRpc { get => _unsafeRpc; set { if (SetProperty(ref _unsafeRpc, value)) RefreshComputed(); } }
    public bool EnableUnsyncedMining { get => _enableUnsyncedMining; set { if (SetProperty(ref _enableUnsyncedMining, value)) RefreshComputed(); } }
    public bool DisableLogFiles { get => _disableLogFiles; set { if (SetProperty(ref _disableLogFiles, value)) RefreshComputed(); } }
    public bool RocksDbNoBlobFiles { get => _rocksDbNoBlobFiles; set { if (SetProperty(ref _rocksDbNoBlobFiles, value)) RefreshComputed(); } }

    public IReadOnlyList<string> LogLevels { get; } = new[] { "off", "error", "warn", "info", "debug", "trace" };
    public IReadOnlyList<string> RocksDbPresets { get; } = new[] { "default", "hdd", "hdd-qd1" };

    public string ResolvedDatabasePath => KeryxPathResolver.ResolveDatabasePath(AppDirectory, IsTestnet);
    public string GeneratedCommand => _argumentBuilder.BuildDisplayCommand(CreateSettings());

    public NodeProcessState ProcessState
    {
        get => _processState;
        private set
        {
            if (!SetProperty(ref _processState, value)) return;
            OnPropertyChanged(nameof(ProcessStateLabel));
            RaiseCommandStates();
        }
    }

    public string ProcessStateLabel => ProcessState switch
    {
        NodeProcessState.Starting => "NODE STARTING",
        NodeProcessState.Running => "NODE RUNNING",
        NodeProcessState.Failed => "NODE FAILED",
        _ => "NODE STOPPED"
    };

    public int? ProcessId { get => _processId; private set => SetProperty(ref _processId, value); }
    public string StatusMessage { get => _statusMessage; private set => SetProperty(ref _statusMessage, value); }
    public string LastError { get => _lastError; private set => SetProperty(ref _lastError, value); }

    public ICommand StartCommand { get; }
    public ICommand StopCommand { get; }
    public ICommand RestartCommand { get; }

    public async Task<bool> KillAttachedNodeAsync()
    {
        var attached = ProcessControl.AttachedNode;
        if (attached is null) return false;

        StatusMessage = "Force stopping attached Keryx node...";

        bool killed;
        if (attached.IsManaged && ProcessId == attached.ProcessId)
        {
            killed = await _processService.ForceKillAsync();
            if (killed)
            {
                ProcessId = null;
                ProcessState = NodeProcessState.Stopped;
                ProcessControl.DetachCommand.Execute(null);
                ProcessControl.DetectCommand.Execute(null);
            }
        }
        else
        {
            killed = await ProcessControl.KillAttachedAsync();
        }

        if (killed)
        {
            LastError = string.Empty;
            StatusMessage = "Keryx process was force stopped.";
            return true;
        }

        LastError = ProcessControl.LastError.Length > 0
            ? ProcessControl.LastError
            : "Impossible de forcer l'arrêt du processus keryxd.";
        StatusMessage = "Force stop failed.";
        return false;
    }

    private async Task StartAsync()
    {
        LastError = string.Empty;
        ProcessState = NodeProcessState.Starting;
        StatusMessage = "Starting Keryx...";
        var result = await _processService.StartAsync(CreateSettings());
        ProcessId = result.ProcessId;
        ProcessState = result.Success ? NodeProcessState.Running : NodeProcessState.Failed;
        StatusMessage = result.Success ? $"Keryx is running (PID {result.ProcessId})." : "Keryx failed to start.";
        LastError = result.Error ?? result.StandardError ?? string.Empty;

        if (result.Success && result.ProcessId is int pid)
        {
            DateTime? started = null;
            try { started = _processService.CurrentProcess?.StartTime; } catch { }
            ProcessControl.AttachManaged(new KeryxProcessInfo(pid, NodeExecutable, started, true));
        }
    }

    private async Task StopAsync()
    {
        StatusMessage = "Requesting graceful stop...";
        var stopped = await _processService.TryRequestCloseAsync(TimeSpan.FromSeconds(3));
        if (stopped)
        {
            ProcessId = null;
            ProcessState = NodeProcessState.Stopped;
            ProcessControl.DetachCommand.Execute(null);
            ProcessControl.DetectCommand.Execute(null);
            StatusMessage = "Keryx stopped.";
            return;
        }

        StatusMessage = "Graceful stop is unavailable. RPC shutdown will be added in the next phase.";
    }

    private async Task RestartAsync()
    {
        var stopped = await _processService.TryRequestCloseAsync(TimeSpan.FromSeconds(3));
        if (!stopped)
        {
            StatusMessage = "Restart cancelled: graceful stop is unavailable.";
            return;
        }

        ProcessId = null;
        ProcessState = NodeProcessState.Stopped;
        ProcessControl.DetachCommand.Execute(null);
        await StartAsync();
    }

    private void ProcessControlOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ProcessControlViewModel.AttachedNode)
            or nameof(ProcessControlViewModel.CanKill)
            or nameof(ProcessControlViewModel.AttachedNodeLabel))
        {
            OnPropertyChanged(nameof(ProcessControl));
        }
    }

    private void OnCommandFailed(object? sender, Exception ex)
    {
        LastError = ex.Message;
        StatusMessage = "Unexpected launcher error.";
        ProcessState = NodeProcessState.Failed;
    }

    private NodeSettings CreateSettings() => new()
    {
        NodeExecutable = NodeExecutable,
        AppDirectory = AppDirectory,
        IsTestnet = IsTestnet,
        UtxoIndex = UtxoIndex,
        AcceptInboundConnections = AcceptInboundConnections,
        DnsPeerDiscovery = DnsPeerDiscovery,
        Upnp = Upnp,
        EnableGrpc = EnableGrpc,
        EnableWrpcJson = EnableWrpcJson,
        EnableWrpcBorsh = EnableWrpcBorsh,
        GrpcPort = GrpcPort,
        WrpcJsonPort = WrpcJsonPort,
        WrpcBorshPort = WrpcBorshPort,
        OutboundPeers = OutboundPeers,
        MaxInboundPeers = MaxInboundPeers,
        AsyncThreads = AsyncThreads,
        RamScale = RamScale,
        RocksDbCacheSizeMb = RocksDbCacheSizeMb,
        RocksDbPreset = RocksDbPreset,
        LogLevel = LogLevel,
        Archival = Archival,
        UnsafeRpc = UnsafeRpc,
        EnableUnsyncedMining = EnableUnsyncedMining,
        DisableLogFiles = DisableLogFiles,
        RocksDbNoBlobFiles = RocksDbNoBlobFiles
    };

    private void ApplyNetworkPorts()
    {
        GrpcPort = IsTestnet ? 22210 : 22110;
        WrpcBorshPort = IsTestnet ? 23210 : 23110;
        WrpcJsonPort = IsTestnet ? 24210 : 24110;
    }

    private void RefreshComputed()
    {
        OnPropertyChanged(nameof(ResolvedDatabasePath));
        OnPropertyChanged(nameof(GeneratedCommand));
    }

    private void RaiseCommandStates()
    {
        (StartCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (StopCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
        (RestartCommand as AsyncRelayCommand)?.RaiseCanExecuteChanged();
    }
}
