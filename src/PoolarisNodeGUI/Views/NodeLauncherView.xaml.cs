using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using PoolarisNodeGUI.Services;
using PoolarisNodeGUI.ViewModels;

namespace PoolarisNodeGUI.Views;

public partial class NodeLauncherView : UserControl
{
    public NodeLauncherView() => InitializeComponent();

    private void BrowseExecutable_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not NodeLauncherViewModel vm) return;

        var dialog = new OpenFileDialog
        {
            Title = "Sélectionner keryxd.exe",
            Filter = "Keryx node (keryxd.exe)|keryxd.exe|Executable (*.exe)|*.exe|All files (*.*)|*.*",
            CheckFileExists = true
        };

        if (dialog.ShowDialog() == true)
            vm.NodeExecutable = dialog.FileName;
    }

    private void BrowseAppDir_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not NodeLauncherViewModel vm) return;

        var dialog = new OpenFolderDialog
        {
            Title = "Sélectionner le répertoire AppDir Keryx",
            Multiselect = false
        };

        if (dialog.ShowDialog() != true) return;

        var selected = dialog.FolderName;
        vm.AppDirectory = KeryxPathResolver.SuggestAppDirectory(selected) ?? selected;
    }

    private async void RpcShutdown_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not NodeLauncherViewModel vm
            || !vm.ProcessControl.CanRpcShutdown
            || vm.ProcessControl.AttachedNode is not { } attached)
        {
            return;
        }

        var dialog = new RpcShutdownConfirmationWindow(
            attached.ProcessId,
            attached.ExecutablePath,
            vm.ProcessControl.RpcEndpoint)
        {
            Owner = Window.GetWindow(this)
        };

        if (dialog.ShowDialog() == true)
            await vm.ShutdownAttachedNodeAsync();
    }

    private async void KillNode_Click(object sender, RoutedEventArgs e)
    {
        if (DataContext is not NodeLauncherViewModel vm || vm.ProcessControl.AttachedNode is not { } attached)
            return;

        var dialog = new ForceKillConfirmationWindow(attached.ProcessId, attached.ExecutablePath)
        {
            Owner = Window.GetWindow(this)
        };

        if (dialog.ShowDialog() == true)
            await vm.KillAttachedNodeAsync();
    }
}
