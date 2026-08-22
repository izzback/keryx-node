using PoolarisNodeGUI.ViewModels;

namespace PoolarisNodeGUI.Tests;

public sealed class MainViewModelTests
{
    [Fact]
    public void StartsOnDashboard()
    {
        var vm = new MainViewModel();
        Assert.IsType<DashboardViewModel>(vm.CurrentPage);
        Assert.Equal("Dashboard", vm.CurrentPageTitle);
    }

    [Theory]
    [InlineData("NodeLauncher", typeof(NodeLauncherViewModel), "Node Launcher")]
    [InlineData("Peers", typeof(PeersViewModel), "Peers")]
    [InlineData("Performance", typeof(PerformanceViewModel), "Performance")]
    [InlineData("Logs", typeof(LogsViewModel), "Logs")]
    [InlineData("Settings", typeof(SettingsViewModel), "Settings")]
    public void NavigationChangesPage(string key, Type expectedType, string expectedTitle)
    {
        var vm = new MainViewModel();
        vm.NavigateCommand.Execute(key);
        Assert.IsType(expectedType, vm.CurrentPage);
        Assert.Equal(expectedTitle, vm.CurrentPageTitle);
    }
}
