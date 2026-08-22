using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows.Input;
using PoolarisNodeGUI.Models;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI.ViewModels;

public sealed class ProcessControlViewModel : ViewModelBase
{
    private readonly RuntimeNodeSession _session;
    private string _status = "No node attached";
    private string _lastError = string.Empty;

    public ProcessControlViewModel(RuntimeNodeSession session)
    {
        _session = session;
        _session.PropertyChanged += SessionOnPropertyChanged;

        DetectCommand = new RelayCommand(_ => Detect());
        AttachCommand = new RelayCommand(_ => AttachSelected(), _ => _session.CanAttach);
        DetachCommand = new RelayCommand(_ => Detach(), _ => _session.CanDetach);

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
    public string AttachedNodeLabel => _session.AttachedNodeLabel;
    public string AttachedExecutable => AttachedNode?.ExecutablePath ?? "—";
    public string AttachedStarted => AttachedNode?.StartedDisplay ?? "—";
    public string AttachedPid => _session.AttachedPid;
    public string RpcEndpoint => _session.RpcEndpointDisplay;

    public string Status { get => _status; private set => SetProperty(ref _status, value); }
    public string LastError { get => _lastError; private set => SetProperty(ref _lastError, value); }

    public ICommand DetectCommand { get; }
    public ICommand AttachCommand { get; }
    public ICommand DetachCommand { get; }

    public void AttachManaged(KeryxProcessInfo process, int rpcPort)
    {
        _session.AttachManaged(process, rpcPort);
        Status = $"Attached to managed node PID {process.ProcessId}.";
        LastError = string.Empty;
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
            Status = $"Attached to PID {_session.AttachedNode?.ProcessId}.";
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
            or nameof(RuntimeNodeSession.IsAttached)
            or nameof(RuntimeNodeSession.AttachedNodeLabel)
            or nameof(RuntimeNodeSession.AttachedPid)
            or nameof(RuntimeNodeSession.CanAttach)
            or nameof(RuntimeNodeSession.CanDetach)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcEndpointVerified))
        {
            RaiseAllSessionProperties();
        }
    }

    private void RaiseAllSessionProperties()
    {
        OnPropertyChanged(nameof(AttachedNode));
        OnPropertyChanged(nameof(IsAttached));
        OnPropertyChanged(nameof(CanKill));
        OnPropertyChanged(nameof(AttachedNodeLabel));
        OnPropertyChanged(nameof(AttachedExecutable));
        OnPropertyChanged(nameof(AttachedStarted));
        OnPropertyChanged(nameof(AttachedPid));
        OnPropertyChanged(nameof(RpcEndpoint));
        RaiseCommandStates();
    }

    private void RaiseCommandStates()
    {
        (AttachCommand as RelayCommand)?.RaiseCanExecuteChanged();
        (DetachCommand as RelayCommand)?.RaiseCanExecuteChanged();
    }
}
