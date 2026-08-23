using System.Windows;
using System.Windows.Input;
using PoolarisNodeGUI.Services;

namespace PoolarisNodeGUI;

public partial class MainWindow : Window
{
    private const double HeaderDragHeight = 72d;

    public MainWindow()
    {
        InitializeComponent();
        PreviewMouseLeftButtonDown += MainWindow_PreviewMouseLeftButtonDown;
        Closed += MainWindow_Closed;
    }

    private void MainWindow_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
            return;

        var position = e.GetPosition(this);
        if (position.Y < 0 || position.Y > HeaderDragHeight)
            return;

        if (e.ClickCount >= 2)
        {
            WindowState = WindowState == WindowState.Maximized
                ? WindowState.Normal
                : WindowState.Maximized;
            e.Handled = true;
            return;
        }

        try
        {
            if (WindowState == WindowState.Maximized)
                WindowState = WindowState.Normal;

            DragMove();
            e.Handled = true;
        }
        catch (InvalidOperationException ex)
        {
            UiErrorLog.Write(ex, "MainWindow.HeaderDrag");
        }
    }

    private void MainWindow_Closed(object? sender, EventArgs e)
    {
        PreviewMouseLeftButtonDown -= MainWindow_PreviewMouseLeftButtonDown;
        Closed -= MainWindow_Closed;
        if (DataContext is IDisposable disposable)
            disposable.Dispose();
    }
}
