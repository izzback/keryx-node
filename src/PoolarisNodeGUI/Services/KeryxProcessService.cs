using System.Diagnostics;
using System.IO;
using System.Text;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public sealed class KeryxProcessService : IDisposable
{
    private readonly KeryxArgumentBuilder _argumentBuilder;
    private Process? _process;
    private readonly StringBuilder _stdout = new();
    private readonly StringBuilder _stderr = new();
    private readonly object _logLock = new();

    public KeryxProcessService(KeryxArgumentBuilder argumentBuilder)
    {
        _argumentBuilder = argumentBuilder;
    }

    public Process? CurrentProcess => _process is { HasExited: false } ? _process : null;

    public async Task<NodeStartResult> StartAsync(NodeSettings settings, CancellationToken cancellationToken = default)
    {
        if (CurrentProcess is not null)
            return new(false, NodeProcessState.Failed, CurrentProcess.Id, Error: "Un node Keryx géré par Poolaris est déjà actif.");

        if (string.IsNullOrWhiteSpace(settings.NodeExecutable) || !File.Exists(settings.NodeExecutable))
            return new(false, NodeProcessState.Failed, Error: "Le fichier keryxd.exe sélectionné est introuvable.");

        if (string.IsNullOrWhiteSpace(settings.AppDirectory))
            return new(false, NodeProcessState.Failed, Error: "Sélectionnez le répertoire AppDir Keryx.");

        if (KeryxPathResolver.LooksLikeDatabaseDirectory(settings.AppDirectory))
            return new(false, NodeProcessState.Failed, Error: "L'AppDir pointe directement vers keryx-mainnet\\datadir. Sélectionnez le répertoire racine Keryx.");

        var conflicts = KeryxPortInspector.FindRpcConflicts(
            settings.EnableGrpc, settings.GrpcPort,
            settings.EnableWrpcBorsh, settings.WrpcBorshPort,
            settings.EnableWrpcJson, settings.WrpcJsonPort);
        if (conflicts.Count > 0)
        {
            var details = string.Join(", ", conflicts.Select(x => $"{x.Name} {x.Port}"));
            return new(false, NodeProcessState.Failed, Error: $"Impossible de démarrer Keryx : port(s) déjà utilisé(s) : {details}.");
        }

        Directory.CreateDirectory(settings.AppDirectory);

        lock (_logLock)
        {
            _stdout.Clear();
            _stderr.Clear();
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = settings.NodeExecutable,
            WorkingDirectory = Path.GetDirectoryName(settings.NodeExecutable) ?? Environment.CurrentDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        foreach (var argument in _argumentBuilder.Build(settings))
            startInfo.ArgumentList.Add(argument);

        try
        {
            var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, e) => AppendBounded(_stdout, e.Data);
            process.ErrorDataReceived += (_, e) => AppendBounded(_stderr, e.Data);

            if (!process.Start())
            {
                process.Dispose();
                return new(false, NodeProcessState.Failed, Error: "Windows n'a pas réussi à créer le processus keryxd.");
            }

            _process = process;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            var exitTask = process.WaitForExitAsync(cancellationToken);
            var startupDelay = Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            var completed = await Task.WhenAny(exitTask, startupDelay).ConfigureAwait(false);

            if (completed == exitTask)
            {
                await exitTask.ConfigureAwait(false);
                var output = Snapshot(_stdout);
                var error = Snapshot(_stderr);
                var exitCode = process.ExitCode;
                _process = null;
                process.Dispose();
                return new(false, NodeProcessState.Failed, ExitCode: exitCode,
                    Error: "Keryx s'est fermé immédiatement après son lancement.",
                    StandardOutput: output, StandardError: error);
            }

            return new(true, NodeProcessState.Running, process.Id, StandardOutput: Snapshot(_stdout), StandardError: Snapshot(_stderr));
        }
        catch (Exception ex)
        {
            _process?.Dispose();
            _process = null;
            return new(false, NodeProcessState.Failed, Error: ex.Message, StandardOutput: Snapshot(_stdout), StandardError: Snapshot(_stderr));
        }
    }

    public async Task<bool> TryRequestCloseAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var process = CurrentProcess;
        if (process is null) return true;

        try
        {
            if (!process.CloseMainWindow()) return false;
            var exitTask = process.WaitForExitAsync(cancellationToken);
            var completed = await Task.WhenAny(exitTask, Task.Delay(timeout, cancellationToken)).ConfigureAwait(false);
            return completed == exitTask;
        }
        catch
        {
            return false;
        }
    }

    public async Task<bool> ForceKillAsync(CancellationToken cancellationToken = default)
    {
        var process = CurrentProcess;
        if (process is null) return true;

        try
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            _process = null;
            process.Dispose();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void AppendBounded(StringBuilder target, string? line)
    {
        if (line is null) return;
        lock (_logLock)
        {
            target.AppendLine(line);
            const int maxCharacters = 32_000;
            if (target.Length > maxCharacters)
                target.Remove(0, target.Length - maxCharacters);
        }
    }

    private string Snapshot(StringBuilder target)
    {
        lock (_logLock) return target.ToString();
    }

    public void Dispose()
    {
        _process?.Dispose();
        _process = null;
    }
}
