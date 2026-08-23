using System.Windows;
using System.Windows.Threading;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI;

public partial class App : Application
{
    public App()
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        UiErrorLog.Write(e.Exception, "Application.DispatcherUnhandledException");

        // A malformed WPF binding must not terminate the whole node manager.
        // Other unexpected exceptions are logged but keep their normal fatal behavior.
        if (UiExceptionPolicy.IsRecoverableBindingException(e.Exception))
            e.Handled = true;
    }

    private static void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        UiErrorLog.Write(e.Exception, "TaskScheduler.UnobservedTaskException");
        e.SetObserved();
    }
}
