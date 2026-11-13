using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

public sealed partial class AboutPage : Page
{
    public AboutPage() => InitializeComponent();

    public AppViewModel Vm => App.Current.ViewModel;
    public UpdatesViewModel Updates => App.Current.Updates;
}
