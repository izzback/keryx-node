using PoolarisNodeGUI.Services;
using PoolarisNodeGUI.ViewModels;

namespace PoolarisNodeGUI.Tests;

public sealed class UiCrashRegressionTests
{
    [Fact]
    public void GeneratedCommandHasPublicSetterForWpfTextBoxBinding()
    {
        var property = typeof(NodeLauncherViewModel).GetProperty(nameof(NodeLauncherViewModel.GeneratedCommand));

        Assert.NotNull(property);
        Assert.NotNull(property!.SetMethod);
        Assert.True(property.SetMethod!.IsPublic);
    }

    [Theory]
    [InlineData("A TwoWay or OneWayToSource binding cannot work on the read-only property 'GeneratedCommand'.")]
    [InlineData("Une liaison TwoWay ou OneWayToSource ne peut pas fonctionner sur la propriété en lecture seule 'GeneratedCommand'.")]
    public void ReadOnlyTwoWayBindingFailureIsRecoverable(string message)
    {
        Assert.True(UiExceptionPolicy.IsRecoverableBindingException(new InvalidOperationException(message)));
    }

    [Fact]
    public void UnrelatedInvalidOperationIsNotSilentlyRecovered()
    {
        Assert.False(UiExceptionPolicy.IsRecoverableBindingException(new InvalidOperationException("unrelated failure")));
    }
}
