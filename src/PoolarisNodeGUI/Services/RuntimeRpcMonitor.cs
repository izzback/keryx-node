using System.ComponentModel;
using System.Windows.Threading;

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
        if (_disposed || _refreshInFlight || _session.AttachedNode is null)
            return;

        _refreshInFlight = true;
        _session.RpcRefreshing = true;
        try
        {
            var snapshot = await _client
                .GetSnapshotAsync(_session.RpcHost, _session.RpcPort, cancellationToken);

            if (!_disposed && _session.AttachedNode is not null)
                _session.SetRpcSnapshot(snapshot);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            if (!_disposed && _session.AttachedNode is not null)
            {
                _session.SetRpcSnapshot(new Models.KeryxRpcSnapshot(
                    null,
                    null,
                    Array.Empty<Models.KeryxPeerInfo>(),
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
            // RefreshNowAsync is defensive by design. This final guard prevents a timer
            // callback from ever escaping into WPF's dispatcher and terminating the GUI.
        }
    }

    private void SessionOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RuntimeNodeSession.AttachedNode)
            or nameof(RuntimeNodeSession.RpcHost)
            or nameof(RuntimeNodeSession.RpcPort))
        {
            UpdateMonitoringState();
        }
    }

    private void UpdateMonitoringState()
    {
        if (_disposed) return;

        if (_session.AttachedNode is null)
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
