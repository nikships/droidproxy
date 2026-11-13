using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

public sealed partial class AdvancedPage : Page
{
    public AdvancedPage() => InitializeComponent();

    public AppViewModel Vm => App.Current.ViewModel;
}
