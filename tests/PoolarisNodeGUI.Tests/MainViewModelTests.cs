using PoolarisNodeGUI.ViewModels;

namespace PoolarisNodeGUI.Tests;

public sealed class MainViewModelTests
{
    [Fact]
    public void StartsOnDashboard()
    {
        using var vm = new MainViewModel();
        Assert.IsType<DashboardViewModel>(vm.CurrentPage);
        Assert.Equal("Dashboard", vm.CurrentPageTitle);
    }

    [Theory]
    [InlineData("NodeLauncher", typeof(NodeLauncherViewModel), "Node Launcher")]
    [InlineData("Peers", typeof(PeersViewModel), "Peers")]
    [InlineData("Performance", typeof(PerformancePageViewModel), "Performance")]
    [InlineData("Logs", typeof(LogsPageViewModel), "Logs")]
    [InlineData("Settings", typeof(SettingsPageViewModel), "Settings")]
    public void NavigationChangesPage(string key, Type expectedType, string expectedTitle)
    {
        using var vm = new MainViewModel();
        vm.NavigateCommand.Execute(key);
        Assert.IsType(expectedType, vm.CurrentPage);
        Assert.Equal(expectedTitle, vm.CurrentPageTitle);
    }
}
