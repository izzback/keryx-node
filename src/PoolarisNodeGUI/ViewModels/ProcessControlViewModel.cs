using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Input;
using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class ProcessControlViewModel : ViewModelBase
{
    private readonly RuntimeNodeSession _session;
    private readonly KeryxGrpcClient _rpcClient = new();
    private string _status = "No node attached";
    private string _lastError = string.Empty;
    private string _rpcHostInput = "127.0.0.1";
    private int _rpcPortInput = 22110;

    public ProcessControlViewModel(RuntimeNodeSession session)
    {
        _session = session;
        _session.PropertyChanged += SessionOnPropertyChanged;

        DetectCommand = new RelayCommand(_ => Detect());
        AttachCommand = new RelayCommand(_ => AttachSelected(), _ => _session.CanAttach);
        DetachCommand = new RelayCommand(_ => Detach(), _ => _session.CanDetach);
        ApplyRpcCommand = new RelayCommand(_ => ApplyRpcEndpoint(), _ => _session.IsAttached);

        SyncRpcInputsFromSession();
        Detect();
    }

    public ObservableCollection<KeryxProcessInfo> DetectedNodes => _session.DetectedNodes;

    public KeryxProcessInfo? SelectedNode
    {
        get => _session.SelectedNode;
        set
        {
            _session.SelectedNode = value;
            OnPropertyChanged();
            RaiseCommandStates();
        }
    }

    public KeryxProcessInfo? AttachedNode => _session.AttachedNode;
    public bool IsAttached => _session.IsAttached;
    public bool CanKill => AttachedNode is not null;
    public bool CanRpcShutdown => AttachedNode is not null
        && _session.RpcEnabled
        && _session.RpcEndpointVerified
        && _session.RpcConnected
        && RpcEndpointPolicy.IsLoopbackHost(_session.RpcHost);
    public string AttachedNodeLabel => _session.AttachedNodeLabel;
    public string AttachedExecutable => AttachedNode?.ExecutablePath ?? "—";
    public string AttachedStarted => AttachedNode?.StartedDisplay ?? "—";
    public string AttachedPid => _session.AttachedPid;
    public string RpcEndpoint => _session.RpcEndpointDisplay;
    public string RpcStatus => _session.RpcStatus;

    public string RpcHostInput
    {
        get => _rpcHostInput;
        set => SetProperty(ref _rpcHostInput, value);
    }

    public int RpcPortInput
    {
        get => _rpcPortInput;
        set => SetProperty(ref _rpcPortInput, value);
    }

    public string Status { get => _status; private set => SetProperty(ref _status, value); }
    public string LastError { get => _lastError; private set => SetProperty(ref _lastError, value); }

    public ICommand DetectCommand { get; }
    public ICommand AttachCommand { get; }
    public ICommand DetachCommand { get; }
    public ICommand ApplyRpcCommand { get; }

    public void AttachManaged(KeryxProcessInfo process, int rpcPort, bool rpcEnabled = true)
    {
        _session.AttachManaged(process, rpcPort, rpcEnabled);
        SyncRpcInputsFromSession();
        Status = $"Attached to managed node PID {process.ProcessId}.";
        LastError = string.Empty;
    }

    public async Task<bool> ShutdownAttachedAsync(CancellationToken cancellationToken = default)
    {
        var identity = AttachedNode;
        if (identity is null)
        {
            LastError = "Aucun processus Keryx n'est attaché.";
            return false;
        }

        if (!CanRpcShutdown)
        {
            LastError = "Shutdown RPC refusé : l'endpoint doit être loopback, vérifié et connecté au node attaché.";
            Status = "RPC shutdown unavailable.";
            return false;
        }

        var host = _session.RpcHost;
        var port = _session.RpcPort;
        Status = $"Requesting Keryx shutdown via {host}:{port}...";
        LastError = string.Empty;

        try
        {
            await _rpcClient.ShutdownAsync(host, port, cancellationToken);

            for (var i = 0; i < 20 && KeryxProcessDetector.StillMatches(identity); i++)
                await Task.Delay(250, cancellationToken);

            if (!KeryxProcessDetector.StillMatches(identity))
            {
                _session.Detach();
                Detect();
                Status = $"PID {identity.ProcessId} stopped cleanly via Keryx RPC.";
            }
            else
            {
                Status = "Keryx accepted Shutdown; waiting for the process to finish.";
            }

            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            LastError = "Shutdown RPC annulé.";
            Status = "RPC shutdown cancelled.";
            return false;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            Status = "RPC shutdown failed. No force kill was attempted.";
            return false;
        }
    }

    public async Task<bool> KillAttachedAsync(CancellationToken cancellationToken = default)
    {
        var identity = AttachedNode;
        if (identity is null)
            return false;

        var result = await ExactProcessTerminator.KillAsync(identity, cancellationToken);
        if (result.Success)
        {
            Status = $"PID {identity.ProcessId} was force stopped.";
            LastError = string.Empty;
            _session.Detach();
            Detect();
            return true;
        }

        LastError = result.Error ?? "Impossible de forcer l’arrêt du node.";
        Status = "Force stop failed.";
        return false;
    }

    private void ApplyRpcEndpoint()
    {
        LastError = string.Empty;

        if (!_session.IsAttached)
        {
            LastError = "Attachez d'abord un processus keryxd.exe.";
            return;
        }

        if (!RpcEndpointPolicy.IsLoopbackHost(RpcHostInput))
        {
            LastError = "Poolaris n'accepte qu'un endpoint RPC local : 127.0.0.1, localhost ou ::1.";
            Status = "RPC endpoint rejected.";
            return;
        }

        if (!RpcEndpointPolicy.IsValidPort(RpcPortInput))
        {
            LastError = "Le port gRPC doit être compris entre 1 et 65535.";
            Status = "RPC endpoint rejected.";
            return;
        }

        _session.ConfigureRpc(RpcHostInput.Trim(), RpcPortInput, enabled: true, verified: false);
        Status = $"Testing RPC endpoint {RpcHostInput.Trim()}:{RpcPortInput}...";
        RaiseAllSessionProperties();
    }

    private void Detect()
    {
        LastError = string.Empty;
        _session.Detect();
        Status = _session.DetectedCount switch
        {
            0 => "No running keryxd.exe detected.",
            1 => "1 Keryx node detected.",
            _ => $"{_session.DetectedCount} Keryx nodes detected."
        };
        OnPropertyChanged(nameof(DetectedNodes));
        OnPropertyChanged(nameof(SelectedNode));
        RaiseAllSessionProperties();
    }

    private void AttachSelected()
    {
        LastError = string.Empty;
        if (_session.AttachSelected())
        {
            SyncRpcInputsFromSession();
            Status = $"Attached to PID {_session.AttachedNode?.ProcessId}. Default RPC endpoint will be verified by GetInfo.";
            RaiseAllSessionProperties();
            return;
        }

        LastError = "Impossible d’attacher le processus sélectionné : il a disparu ou son identité a changé.";
        Status = "Attach failed.";
        Detect();
    }

    private void Detach()
    {
        _session.Detach();
        Status = "Node detached. The keryxd process keeps running.";
        LastError = string.Empty;
        RaiseAllSessionProperties();
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.SelectedNode))
            OnPropertyChanged(nameof(SelectedNode));

        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort))
        {
            SyncRpcInputsFromSession();
        }

        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.IsAttached)
            or nameof(RuntimeNodeSession.AttachedNodeLabel)
            or nameof(RuntimeNodeSession.AttachedPid)
            or nameof(RuntimeNodeSession.CanAttach)
            or nameof(RuntimeNodeSession.CanDetach)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcEnabled)
            or nameof(RuntimeNodeSession.RpcEndpointVerified)
            or nameof(RuntimeNodeSession.RpcConnected)
            or nameof(RuntimeNodeSession.RpcStatus))
        {
            RaiseAllSessionProperties();
        }
    }

    private void SyncRpcInputsFromSession()
    {
        RpcHostInput = _session.RpcHost;
        RpcPortInput = _session.RpcPort;
    }

    private void RaiseAllSessionProperties()
    {
        OnPropertyChanged(nameof(AttachedNode));
        OnPropertyChanged(nameof(IsAttached));
        OnPropertyChanged(nameof(CanKill));
        OnPropertyChanged(nameof(CanRpcShutdown));
        OnPropertyChanged(nameof(AttachedNodeLabel));
        OnPropertyChanged(nameof(AttachedExecutable));
        OnPropertyChanged(nameof(AttachedStarted));
        OnPropertyChanged(nameof(AttachedPid));
        OnPropertyChanged(nameof(RpcEndpoint));
        OnPropertyChanged(nameof(RpcStatus));
        RaiseCommandStates();
    }

    private void RaiseCommandStates()
    {
        (AttachCommand as RelayCommand)?.RaiseCanExecuteChanged();
        (DetachCommand as RelayCommand)?.RaiseCanExecuteChanged();
        (ApplyRpcCommand as RelayCommand)?.RaiseCanExecuteChanged();
    }
}
