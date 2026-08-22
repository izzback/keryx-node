using System.Diagnostics;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public static class ExactProcessTerminator
{
    public static async Task<(bool Success, string? Error)> KillAsync(KeryxProcessInfo identity, CancellationToken cancellationToken = default)
    {
        if (!KeryxProcessDetector.StillMatches(identity))
            return (false, "Le processus sélectionné n’existe plus ou son identité a changé.");

        try
        {
            using var process = Process.GetProcessById(identity.ProcessId);
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            return (true, null);
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }
}
