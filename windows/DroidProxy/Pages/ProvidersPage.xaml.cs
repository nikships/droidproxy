using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

public sealed partial class ProvidersPage : Page
{
    public ProvidersPage() => InitializeComponent();

    public AppViewModel Vm => App.Current.ViewModel;
}
