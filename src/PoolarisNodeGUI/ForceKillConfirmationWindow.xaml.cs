using System.Windows;

namespace PoolarisNodeGUI;

public partial class ForceKillConfirmationWindow : Window
{
    public ForceKillConfirmationWindow(int processId, string executable)
    {
        InitializeComponent();
        ProcessText.Text = $"PID {processId} — {executable}";
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
