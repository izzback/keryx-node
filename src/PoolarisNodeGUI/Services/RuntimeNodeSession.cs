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

    public bool IsAttached => AttachedNode is not null;
    public bool CanAttach => SelectedNode is not null && !Equals(SelectedNode, AttachedNode);
    public bool CanDetach => AttachedNode is not null;
    public string AttachedNodeLabel => AttachedNode?.DisplayName ?? "No node attached";
    public string AttachedPid => AttachedNode?.ProcessId.ToString() ?? "—";
    public string RpcEndpointDisplay => $"{RpcHost}:{RpcPort} ({(RpcEndpointVerified ? "verified" : "default")})";

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
            AttachedNode = null;

        OnPropertyChanged(nameof(DetectedCount));
    }

    public bool AttachSelected()
    {
        if (SelectedNode is null || !KeryxProcessDetector.StillMatches(SelectedNode))
            return false;

        AttachedNode = SelectedNode;
        SetRpcEndpoint("127.0.0.1", 22110, verified: false);
        return true;
    }

    public void AttachManaged(KeryxProcessInfo node, int rpcPort)
    {
        AttachedNode = node with { IsManaged = true };
        SelectedNode = AttachedNode;
        SetRpcEndpoint("127.0.0.1", rpcPort, verified: true);
        if (DetectedNodes.All(x => x.ProcessId != node.ProcessId))
            DetectedNodes.Add(AttachedNode);
        OnPropertyChanged(nameof(DetectedCount));
    }

    public void SetRpcEndpoint(string host, int port, bool verified)
    {
        RpcHost = string.IsNullOrWhiteSpace(host) ? "127.0.0.1" : host.Trim();
        RpcPort = port is >= 1 and <= 65535 ? port : 22110;
        RpcEndpointVerified = verified;
    }

    public void Detach()
    {
        AttachedNode = null;
        RpcEndpointVerified = false;
    }

    public int DetectedCount => DetectedNodes.Count;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
