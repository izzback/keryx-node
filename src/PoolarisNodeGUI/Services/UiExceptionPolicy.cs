namespace PoolarisNodeGUI.Services;

public static class UiExceptionPolicy
{
    public static bool IsRecoverableBindingException(Exception exception)
    {
        if (exception is not InvalidOperationException)
            return false;

        var message = exception.Message ?? string.Empty;
        var mentionsBindingMode = message.Contains("TwoWay", StringComparison.OrdinalIgnoreCase)
            || message.Contains("OneWayToSource", StringComparison.OrdinalIgnoreCase);
        var mentionsReadOnly = message.Contains("read-only", StringComparison.OrdinalIgnoreCase)
            || message.Contains("lecture seule", StringComparison.OrdinalIgnoreCase);

        return mentionsBindingMode && mentionsReadOnly;
    }
}
