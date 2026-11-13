using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace DroidProxy;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        // The app is always dark, so the system caption buttons must be drawn for a dark surface.
        AppWindow.TitleBar.PreferredTheme = TitleBarTheme.Dark;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));

        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var size = new SizeInt32(Math.Min((int)(1000 * scale), work.Width), Math.Min((int)(720 * scale), work.Height));
        AppWindow.MoveAndResize(new RectInt32(
            work.X + (work.Width - size.Width) / 2, work.Y + (work.Height - size.Height) / 2, size.Width, size.Height));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(760 * scale);
            presenter.PreferredMinimumHeight = (int)(560 * scale);
        }

        // Closing the window hides to the tray, where Quit lives; without a tray it quits.
        AppWindow.Closing += async (_, args) =>
        {
            if (App.Current.IsQuitting) return;
            args.Cancel = true;
            if (App.Current.HasTray) AppWindow.Hide();
            else await App.Current.QuitAsync();
        };

        Nav.SelectedItem = Nav.MenuItems[0];
    }

    public AppViewModel Vm => App.Current.ViewModel;

    private void OnNavigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var page = (args.SelectedItem as NavigationViewItem)?.Tag switch
        {
            "providers" => typeof(ProvidersPage),
            "network" => typeof(NetworkPage),
            "advanced" => typeof(AdvancedPage),
            "about" => typeof(AboutPage),
            _ => typeof(OverviewPage),
        };
        ContentFrame.Navigate(page);
        ContentFrame.BackStack.Clear();
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);
}
