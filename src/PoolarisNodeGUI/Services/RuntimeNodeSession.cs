using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public sealed class RuntimeNodeSession : INotifyPropertyChanged
{
    private KeryxProcessInfo? _selectedNode;
    private KeryxProcessInfo? _attachedNode;

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

    public bool IsAttached => AttachedNode is not null;
    public bool CanAttach => SelectedNode is not null && !Equals(SelectedNode, AttachedNode);
    public bool CanDetach => AttachedNode is not null;
    public string AttachedNodeLabel => AttachedNode?.DisplayName ?? "No node attached";
    public string AttachedPid => AttachedNode?.ProcessId.ToString() ?? "—";

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
        return true;
    }

    public void AttachManaged(KeryxProcessInfo node)
    {
        AttachedNode = node with { IsManaged = true };
        SelectedNode = AttachedNode;
        if (DetectedNodes.All(x => x.ProcessId != node.ProcessId))
            DetectedNodes.Add(AttachedNode);
        OnPropertyChanged(nameof(DetectedCount));
    }

    public void Detach() => AttachedNode = null;

    public int DetectedCount => DetectedNodes.Count;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
