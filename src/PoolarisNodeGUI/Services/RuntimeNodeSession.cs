using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public sealed class RuntimeNodeSession : INotifyPropertyChanged
{
    private KeryxProcessInfo? _selectedNode;
    private KeryxProcessInfo? _attachedNode;
    private string _rpcHost = "127.0.0.1";
    private int _rpcPort = 22110;
    private bool _rpcEndpointVerified;
    private bool _rpcEnabled = true;
    private KeryxRpcSnapshot? _rpcSnapshot;
    private DateTime? _rpcLastUpdated;
    private bool _rpcRefreshing;

    public ObservableCollection<KeryxProcessInfo> DetectedNodes { get; } = new();

    public KeryxProcessInfo? SelectedNode
    {
        get => _selectedNode;
        set
        {
            if (Equals(_selectedNode, value)) return;
            _selectedNode = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanAttach));
        }
    }

    public KeryxProcessInfo? AttachedNode
    {
        get => _attachedNode;
        private set
        {
            if (Equals(_attachedNode, value)) return;
            _attachedNode = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsAttached));
            OnPropertyChanged(nameof(CanAttach));
            OnPropertyChanged(nameof(CanDetach));
            OnPropertyChanged(nameof(AttachedNodeLabel));
            OnPropertyChanged(nameof(AttachedPid));
        }
    }

    public string RpcHost
    {
        get => _rpcHost;
        private set
        {
            if (_rpcHost == value) return;
            _rpcHost = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcEndpointDisplay));
        }
    }

    public int RpcPort
    {
        get => _rpcPort;
        private set
        {
            if (_rpcPort == value) return;
            _rpcPort = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcEndpointDisplay));
        }
    }

    public bool RpcEndpointVerified
    {
        get => _rpcEndpointVerified;
        private set
        {
            if (_rpcEndpointVerified == value) return;
            _rpcEndpointVerified = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcEndpointDisplay));
        }
    }

    public bool RpcEnabled
    {
        get => _rpcEnabled;
        private set
        {
            if (_rpcEnabled == value) return;
            _rpcEnabled = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcEndpointDisplay));
            OnPropertyChanged(nameof(RpcConnected));
            OnPropertyChanged(nameof(RpcStatus));
        }
    }

    public KeryxRpcSnapshot? RpcSnapshot
    {
        get => _rpcSnapshot;
        private set
        {
            if (ReferenceEquals(_rpcSnapshot, value)) return;
            _rpcSnapshot = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcConnected));
            OnPropertyChanged(nameof(RpcStatus));
            OnPropertyChanged(nameof(RpcError));
        }
    }

    public DateTime? RpcLastUpdated
    {
        get => _rpcLastUpdated;
        private set
        {
            if (_rpcLastUpdated == value) return;
            _rpcLastUpdated = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcLastUpdatedDisplay));
        }
    }

    public bool RpcRefreshing
    {
        get => _rpcRefreshing;
        internal set
        {
            if (_rpcRefreshing == value) return;
            _rpcRefreshing = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(RpcStatus));
        }
    }

    public bool IsAttached => AttachedNode is not null;
    public bool CanAttach => SelectedNode is not null && !Equals(SelectedNode, AttachedNode);
    public bool CanDetach => AttachedNode is not null;
    public string AttachedNodeLabel => AttachedNode?.DisplayName ?? "No node attached";
    public string AttachedPid => AttachedNode?.ProcessId.ToString() ?? "—";
    public string RpcEndpointDisplay => !RpcEnabled
        ? "Disabled"
        : $"{RpcHost}:{RpcPort} ({(RpcEndpointVerified ? "verified" : "unverified")})";
    public bool RpcConnected => IsAttached && RpcEnabled && RpcSnapshot is { Info: not null };
    public string RpcError => RpcSnapshot?.Error ?? string.Empty;
    public string RpcStatus => !IsAttached
        ? "Unavailable"
        : !RpcEnabled
            ? "Disabled"
            : RpcRefreshing && RpcSnapshot is null
                ? "Connecting..."
                : RpcConnected
                    ? string.IsNullOrWhiteSpace(RpcError) ? "Connected" : "Connected (partial)"
                    : string.IsNullOrWhiteSpace(RpcError) ? "Unavailable" : "Error";
    public string RpcLastUpdatedDisplay => RpcLastUpdated?.ToLocalTime().ToString("HH:mm:ss") ?? "—";

    public void Detect()
    {
        var previousSelectedPid = SelectedNode?.ProcessId;
        var discovered = KeryxProcessDetector.Detect();

        DetectedNodes.Clear();
        foreach (var node in discovered)
            DetectedNodes.Add(node);

        SelectedNode = previousSelectedPid.HasValue
            ? DetectedNodes.FirstOrDefault(x => x.ProcessId == previousSelectedPid.Value)
            : DetectedNodes.FirstOrDefault();

        if (AttachedNode is not null && !KeryxProcessDetector.StillMatches(AttachedNode))
            Detach();

        OnPropertyChanged(nameof(DetectedCount));
    }

    public bool AttachSelected()
    {
        if (SelectedNode is null || !KeryxProcessDetector.StillMatches(SelectedNode))
            return false;

        AttachedNode = SelectedNode;
        ConfigureRpc("127.0.0.1", 22110, enabled: true, verified: false);
        return true;
    }

    public void AttachManaged(KeryxProcessInfo node, int rpcPort, bool rpcEnabled = true)
    {
        AttachedNode = node with { IsManaged = true };
        SelectedNode = AttachedNode;
        ConfigureRpc("127.0.0.1", rpcPort, enabled: rpcEnabled, verified: false);
        if (DetectedNodes.All(x => x.ProcessId != node.ProcessId))
            DetectedNodes.Add(AttachedNode);
        OnPropertyChanged(nameof(DetectedCount));
    }

    public void ConfigureRpc(string host, int port, bool enabled, bool verified)
    {
        RpcHost = string.IsNullOrWhiteSpace(host) ? "127.0.0.1" : host.Trim();
        RpcPort = port is >= 1 and <= 65535 ? port : 22110;
        RpcEnabled = enabled;
        RpcEndpointVerified = enabled && verified;
        ClearRpcSnapshot();
    }

    public void SetRpcEndpoint(string host, int port, bool verified)
        => ConfigureRpc(host, port, enabled: true, verified);

    internal void SetRpcSnapshot(KeryxRpcSnapshot snapshot)
    {
        RpcSnapshot = snapshot;
        RpcLastUpdated = DateTime.UtcNow;
        if (RpcEnabled && IsAttached && snapshot.Info is not null)
            RpcEndpointVerified = true;
    }

    internal void ClearRpcSnapshot()
    {
        RpcSnapshot = null;
        RpcLastUpdated = null;
        RpcRefreshing = false;
    }

    public void Detach()
    {
        AttachedNode = null;
        RpcEndpointVerified = false;
        ClearRpcSnapshot();
    }

    public int DetectedCount => DetectedNodes.Count;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
