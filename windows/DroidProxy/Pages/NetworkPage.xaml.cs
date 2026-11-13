using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

public sealed partial class NetworkPage : Page
{
    public NetworkPage() => InitializeComponent();

    public AppViewModel Vm => App.Current.ViewModel;
}
