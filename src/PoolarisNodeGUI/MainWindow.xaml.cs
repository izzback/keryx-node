using System.Windows;

namespace PoolarisNodeGUI;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Closed += MainWindow_Closed;
    }

    private void MainWindow_Closed(object? sender, EventArgs e)
    {
        Closed -= MainWindow_Closed;
        if (DataContext is IDisposable disposable)
            disposable.Dispose();
    }
}
