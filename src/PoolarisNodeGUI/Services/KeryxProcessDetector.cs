using System.Diagnostics;
using PoolarisNodeGUI.Models;

namespace PoolarisNodeGUI.Services;

public static class KeryxProcessDetector
{
    public static IReadOnlyList<KeryxProcessInfo> Detect()
    {
        var result = new List<KeryxProcessInfo>();

        foreach (var process in Process.GetProcessesByName("keryxd").OrderBy(p => p.Id))
        {
            try
            {
                string executable;
                try
                {
                    executable = process.MainModule?.FileName ?? "keryxd.exe";
                }
                catch
                {
                    executable = "keryxd.exe";
                }

                DateTime? startTime;
                try
                {
                    startTime = process.StartTime;
                }
                catch
                {
                    startTime = null;
                }

                result.Add(new KeryxProcessInfo(process.Id, executable, startTime));
            }
            finally
            {
                process.Dispose();
            }
        }

        return result;
    }

    public static bool StillMatches(KeryxProcessInfo identity)
    {
        try
        {
            using var process = Process.GetProcessById(identity.ProcessId);
            if (process.HasExited || !string.Equals(process.ProcessName, "keryxd", StringComparison.OrdinalIgnoreCase))
                return false;

            if (identity.StartTime.HasValue)
            {
                try
                {
                    if (process.StartTime != identity.StartTime.Value)
                        return false;
                }
                catch
                {
                    return false;
                }
            }

            if (!string.Equals(identity.ExecutablePath, "keryxd.exe", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    if (!string.Equals(process.MainModule?.FileName, identity.ExecutablePath, StringComparison.OrdinalIgnoreCase))
                        return false;
                }
                catch
                {
                    return false;
                }
            }

            return true;
        }
        catch
        {
            return false;
        }
    }
}
