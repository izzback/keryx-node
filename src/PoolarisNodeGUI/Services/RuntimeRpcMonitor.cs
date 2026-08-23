using System.ComponentModel;
using System.Windows.Threading;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public sealed class RuntimeRpcMonitor : IDisposable
{
    private readonly RuntimeNodeSession _session;
    private readonly KeryxGrpcClient _client;
    private readonly DispatcherTimer _timer;
    private bool _disposed;
    private bool _refreshInFlight;

    public RuntimeRpcMonitor(RuntimeNodeSession session, KeryxGrpcClient? client = null)
    {
        _session = session;
        _client = client ?? new KeryxGrpcClient();
        _session.PropertyChanged += SessionOnPropertyChanged;

        _timer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(2)
        };
        _timer.Tick += TimerOnTick;

        UpdateMonitoringState();
    }

    public async Task RefreshNowAsync(CancellationToken cancellationToken = default)
    {
        if (_disposed || _refreshInFlight || _session.AttachedNode is null || !_session.RpcEnabled)
            return;

        _refreshInFlight = true;
        _session.RpcRefreshing = true;
        try
        {
            var attachedIdentity = _session.AttachedNode;
            var host = _session.RpcHost;
            var port = _session.RpcPort;

            var snapshot = await _client
                .GetSnapshotAsync(host, port, cancellationToken)
                .ConfigureAwait(true);

            if (!_disposed
                && _session.RpcEnabled
                && _session.AttachedNode is not null
                && Equals(_session.AttachedNode, attachedIdentity)
                && _session.RpcHost == host
                && _session.RpcPort == port)
            {
                _session.SetRpcSnapshot(snapshot);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            if (!_disposed && _session.AttachedNode is not null && _session.RpcEnabled)
            {
                _session.SetRpcSnapshot(new KeryxRpcSnapshot(
                    null,
                    null,
                    Array.Empty<KeryxPeerInfo>(),
                    ex.Message));
            }
        }
        finally
        {
            _refreshInFlight = false;
            if (!_disposed)
                _session.RpcRefreshing = false;
        }
    }

    private async void TimerOnTick(object? sender, EventArgs e)
    {
        try
        {
            await RefreshNowAsync();
        }
        catch
        {
            // Never allow a background refresh callback to escape into WPF's dispatcher.
        }
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort)
            or nameof(RuntimeNodeSession.RpcEnabled))
        {
            UpdateMonitoringState();
        }
    }

    private void UpdateMonitoringState()
    {
        if (_disposed) return;

        if (_session.AttachedNode is null || !_session.RpcEnabled)
        {
            _timer.Stop();
            _session.ClearRpcSnapshot();
            return;
        }

        if (!_timer.IsEnabled)
            _timer.Start();

        _ = RefreshNowAsync();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _timer.Stop();
        _timer.Tick -= TimerOnTick;
        _session.PropertyChanged -= SessionOnPropertyChanged;
    }
}
