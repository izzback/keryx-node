using System.Windows;

namespace PoolarisNodeGUI;

public partial class RpcShutdownConfirmationWindow : Window
{
    public RpcShutdownConfirmationWindow(int processId, string executable, string endpoint)
    {
        InitializeComponent();
        ProcessText.Text = $"PID {processId} — {executable}";
        EndpointText.Text = endpoint;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }
}
