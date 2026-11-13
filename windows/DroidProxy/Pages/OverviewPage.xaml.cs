using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

public sealed partial class OverviewPage : Page
{
    public OverviewPage() => InitializeComponent();

    public AppViewModel Vm => App.Current.ViewModel;
}
