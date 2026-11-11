using System.IO;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

namespace ZoneXM.Notifications;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, "ZoneXM.Notifications.Singleton", out var first);
        if (!first)
        {
            NativeTray.ShowExisting();
            return;
        }
        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(initialization =>
            {
                SynchronizationContext.SetSynchronizationContext(
                    new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                _ = new BridgeApplication();
            });
        }
        catch (Exception error)
        {
            NativeTray.ShowError($"ZoneXM could not start ({error.GetType().Name}, 0x{error.HResult:X8}).");
        }
        finally { mutex.ReleaseMutex(); }
    }
}

public sealed partial class BridgeApplication : Application
{
    private BridgeWindow? window;

    internal BridgeApplication()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new BridgeWindow();
        window.Activate();
    }
}

internal sealed class BridgeWindow : Window
{
    private readonly string directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZoneXM");
    private readonly NotificationBridge bridge;
    private readonly ActivityLog activity = new();
    private readonly TextBlock logView = new()
    {
        IsTextSelectionEnabled = true,
        TextWrapping = TextWrapping.Wrap,
        FontSize = 12
    };
    private readonly ScrollViewer logScroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
    };
    private long logVersion = -1;
    private readonly AudioDucker audio;
    private readonly DispatcherTimer audioTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly TextBlock audioStatus = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 12) };
    private readonly UserNotificationListener listener = UserNotificationListener.Current;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 10) };
    private readonly StackPanel apps = new();
    private readonly Button access = new() { Content = "Allow notification access / Start", Padding = new Thickness(12, 6, 12, 6) };
    private readonly Button pause = new() { Content = "Pause forwarding", IsEnabled = false };
    private readonly HashSet<string> allowed = new(StringComparer.Ordinal);
    private readonly HashSet<string> listed = new(StringComparer.Ordinal);
    private HashSet<(string App, uint Id, long Created)> observed = [];
    private bool observedPrimed;
    private bool running;
    private bool busy;
    private int failures;
    private DateTimeOffset retryAt;
    private bool closing;
    private bool settingsValid = true;
    private NativeTray? tray;
    private InputNonClientPointerSource? captionSource;
    private Grid? dragArea;
    private XamlRoot? chromeRoot;
    private readonly Slider duckSlider = new() { Minimum = 0, Maximum = 100, StepFrequency = 1, Value = 15 };
    private readonly TextBlock duckLevel = new();
    private readonly DispatcherTimer settingsTimer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private int epoch;
    private string SettingsPath => Path.Combine(directory, "helper-settings.json");

    internal BridgeWindow()
    {
        Title = "ZoneXM Companion";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "App.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(780, 740));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
            presenter.SetBorderAndTitleBar(true, false);
        Directory.CreateDirectory(directory);
        bridge = new NotificationBridge(Path.Combine(directory, "notification.txt"), activity.Add);
        bridge.Clear();
        audio = new AudioDucker(Path.Combine(directory, "alert.flag"), activity.Add);
        logView.Style = (Style)Application.Current.Resources["CompanionTechnicalStyle"];
        status.Style = (Style)Application.Current.Resources["CompanionTechnicalStyle"];
        audioStatus.Style = (Style)Application.Current.Resources["CompanionTelemetryStyle"];
        var root = new StackPanel { Margin = new Thickness(24), Spacing = 8 };
        var tabs = new TabView
        {
            IsAddTabButtonVisible = false,
            CanDragTabs = false,
            CanReorderTabs = false,
            VerticalAlignment = VerticalAlignment.Stretch,
            Margin = new Thickness(12, 0, 12, 12)
        };
        var settingsTab = new TabViewItem
        {
            IsClosable = false,
            Header = TabHeading("Settings"),
            Content = Glass(new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto })
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settingsTab, "Settings");
        tabs.TabItems.Add(settingsTab);
        var logPanel = new Grid { Margin = new Thickness(16), RowSpacing = 8 };
        logPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        logPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var logHeader = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        logHeader.Children.Add(SubtitleText("Activity log", true));
        logHeader.Children.Add(new TextBlock
        {
            Text = "Activity (last 200 events, local time, memory only). No notification titles or bodies.\nForwarded means written to the banner file, not proof of in-game display.",
            TextWrapping = TextWrapping.Wrap
        });
        var clearLog = new Button { Content = "Clear log", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        clearLog.Click += (_, _) => { activity.Clear(); RefreshLog(); };
        logHeader.Children.Add(clearLog);
        logPanel.Children.Add(logHeader);
        logScroll.Content = logView;
        Grid.SetRow(logScroll, 1);
        logPanel.Children.Add(logScroll);
        var activityTab = new TabViewItem { Header = TabHeading("Activity log"), Content = Glass(logPanel), IsClosable = false };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(activityTab, "Activity log");
        tabs.TabItems.Add(activityTab);
        Content = CreateShell(tabs);
        root.Children.Add(SubtitleText("Windows Notification Center", true));
        root.Children.Add(new TextBlock
        {
            Text = "Forwarding is opt-in for each app. Newly discovered apps stay unchecked. Selected apps can forward entries hidden " +
                "by Do Not Disturb or disabled Windows banners. Existing history is skipped. " +
                "Windows grants broad read access; only checked apps below may forward locally.\n\n" +
                "Text stays local, is never logged, and is briefly written to the game's banner file. " +
                "It may be visible to anyone watching your game or stream. Original notifications are never changed. " +
                "Minimize or Close hides this window to the tray. Use Exit in the tray menu to stop and restore audio. " +
                "Audio ducking is built in and does not need PowerShell or notification permission.",
            TextWrapping = TextWrapping.Wrap
        });
        var duckAudio = new CheckBox
        {
            Content = "Duck other apps during dialogue/combat",
            IsChecked = true,
            Margin = new Thickness(0, 12, 0, 0)
        };
        RoutedEventHandler updateDucking = (_, _) =>
        {
            audio.Enabled = duckAudio.IsChecked == true;
            activity.Add(audio.Enabled ? "Audio ducking enabled by user." : "Audio ducking disabled by user; restoring volumes.");
        };
        duckAudio.Checked += updateDucking;
        duckAudio.Unchecked += updateDucking;
        root.Children.Add(duckAudio);
        root.Children.Add(duckLevel);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(duckSlider, "Volume retained while ducked (%)");
        root.Children.Add(duckSlider);
        root.Children.Add(new TextBlock
        {
            Text = "0% = mute; 100% = unchanged. Percentage of each app's original volume.",
            TextWrapping = TextWrapping.Wrap
        });
        root.Children.Add(audioStatus);
        audioTimer.Tick += (_, _) => { audioStatus.Text = audio.Status; RefreshLog(); };
        var buttons = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 14, 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        foreach (var button in new[] { access, pause })
        {
            button.Content = new TextBlock { Text = (string)button.Content, Style = (Style)Application.Current.Resources["CompanionButtonLabelStyle"] };
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        Grid.SetColumn(pause, 1);
        buttons.Children.Add(access);
        buttons.Children.Add(pause);
        root.Children.Add(buttons);
        root.Children.Add(status);
        root.Children.Add(SubtitleText("Apps", true));
        root.Children.Add(new TextBlock { Text = "Seen in Notification Center. Unchecked until you opt in.", TextWrapping = TextWrapping.Wrap });
        root.Children.Add(apps);
        access.Click += async (_, _) => await StartAsync();
        pause.Click += (_, _) => Stop("Paused. Starting again skips accumulated history.");
        timer.Tick += async (_, _) => await PollAsync();
        AppWindow.Closing += (_, args) =>
        {
            if (closing) return;
            if (tray?.Available == true) { args.Cancel = true; AppWindow.Hide(); }
            else Shutdown();
        };
        Closed += (_, _) => Shutdown();
        try
        {
            var settings = HelperSettings.Load(SettingsPath);
            foreach (var id in settings.AllowedApps) allowed.Add(id);
            audio.DuckPercent = settings.DuckPercent;
            duckSlider.Value = settings.DuckPercent;
            foreach (var id in allowed) AddApp(id, id);
            status.Text = "Ready. Start to discover apps, then check only those you want to forward.";
            if (File.Exists(Path.Combine(directory, "notification-apps.json")) && !File.Exists(SettingsPath))
                activity.Add("Legacy exclusions were not converted to consent. All apps start unchecked; opt in individually.");
        }
        catch (Exception error)
        {
            settingsValid = false;
            access.IsEnabled = false;
            duckSlider.IsEnabled = false;
            Report("Could not load helper settings; forwarding disabled", error);
        }
        duckLevel.Text = $"Volume retained while ducked: {audio.DuckPercent}%";
        duckSlider.ValueChanged += (_, args) =>
        {
            audio.DuckPercent = (int)Math.Round(args.NewValue);
            duckLevel.Text = $"Volume retained while ducked: {audio.DuckPercent}%";
            settingsTimer.Stop();
            settingsTimer.Start();
        };
        settingsTimer.Tick += (_, _) =>
        {
            settingsTimer.Stop();
            SaveSettings();
        };
        try
        {
            tray = new NativeTray(WinRT.Interop.WindowNative.GetWindowHandle(this),
                ShowFromTray, Exit,
                () => DispatcherQueue.TryEnqueue(() => AppWindow.Hide()),
                message => activity.Add(message));
        }
        catch (Exception error)
        {
            Report("Tray unavailable; Close will exit instead", error);
        }
        audio.Start();
        audioTimer.Start();
        activity.Add("Companion started; audio independent of notification permission.");
        if (settingsValid && listener.GetAccessStatus() == UserNotificationListenerAccessStatus.Allowed)
        {
            activity.Add("Notification access already granted; resuming forwarding for opted-in apps only.");
            DispatcherQueue.TryEnqueue(async () => await StartAsync());
        }
    }

    private static TextBlock TabHeading(string value) => new()
    {
        Text = value.ToUpperInvariant(),
        Style = (Style)Application.Current.Resources["CompanionTabStyle"]
    };

    private FrameworkElement SubtitleText(string value, bool title, double size = 21)
    {
        if (title) return new TitleLogo(value.ToUpperInvariant(), size) { Log = activity.Add };
        return new TextBlock { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap };
    }

    private static Border Glass(UIElement child) =>
        new() { Style = (Style)Application.Current.Resources["CompanionGlassStyle"], Child = child };

    private Grid CreateShell(TabView tabs)
    {
        var shell = new Grid
        {
            RequestedTheme = ElementTheme.Dark,
            Style = (Style)Application.Current.Resources["CompanionShellStyle"]
        };
        foreach (var theme in Application.Current.Resources.ThemeDictionaries)
        {
            var resources = new ResourceDictionary();
            foreach (var resource in (ResourceDictionary)theme.Value)
                resources[resource.Key] = resource.Value;
            shell.Resources.ThemeDictionaries[theme.Key] = resources;
        }
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var backdrop = new Border { Style = (Style)Application.Current.Resources["CompanionBackdropStyle"] };
        Grid.SetRowSpan(backdrop, 2);
        shell.Children.Add(backdrop);
        var header = new Grid { MinHeight = 94, Style = (Style)Application.Current.Resources["CompanionHeaderStyle"] };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var grain = new Border { Style = (Style)Application.Current.Resources["CompanionGrainStyle"] };
        Grid.SetColumnSpan(grain, 2);
        header.Children.Add(grain);
        var rail = new Border { Height = 3, VerticalAlignment = VerticalAlignment.Bottom, Style = (Style)Application.Current.Resources["CompanionRustStyle"] };
        Grid.SetColumnSpan(rail, 2);
        header.Children.Add(rail);
        dragArea = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        var branding = new Grid { Margin = new Thickness(24, 14, 12, 14), ColumnSpacing = 14 };
        branding.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        branding.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        branding.Children.Add(new Image
        {
            Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/Brand.png")),
            Width = 56,
            Height = 56,
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["CompanionBrandStyle"]
        });
        var heading = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        heading.Children.Add(new TitleLogo { Log = activity.Add });
        heading.Children.Add(SubtitleText("Audio ducking and notification companion", false, 14));
        Grid.SetColumn(heading, 1);
        branding.Children.Add(heading);
        dragArea.Children.Add(branding);
        header.Children.Add(dragArea);
        var controls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 8, 8, 0),
            Spacing = 4
        };
        var minimize = CaptionButton("Minimize to tray", "\uE921");
        minimize.Click += (_, _) =>
        {
            if (tray?.Available == true) AppWindow.Hide();
            else if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.Minimize();
        };
        var maximize = CaptionButton("Maximize or restore", "\uE922");
        maximize.Click += (_, _) =>
        {
            if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
            if (presenter.State == OverlappedPresenterState.Maximized) presenter.Restore();
            else presenter.Maximize();
        };
        var close = CaptionButton("Close to tray", "\uE8BB");
        close.Click += (_, _) =>
        {
            if (tray?.Available == true) AppWindow.Hide();
            else Exit();
        };
        controls.Children.Add(minimize);
        controls.Children.Add(maximize);
        controls.Children.Add(close);
        Grid.SetColumn(controls, 1);
        header.Children.Add(controls);
        shell.Children.Add(header);
        Grid.SetRow(tabs, 1);
        shell.Children.Add(tabs);
        shell.Loaded += (_, _) =>
        {
            captionSource = InputNonClientPointerSource.GetForWindowId(AppWindow.Id);
            chromeRoot = shell.XamlRoot;
            chromeRoot.Changed += ChromeRootChanged;
            UpdateDragRegion();
        };
        dragArea.SizeChanged += (_, _) => UpdateDragRegion();
        return shell;
    }

    private static Button CaptionButton(string name, string glyph)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            Width = 40,
            Height = 36,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0)
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        return button;
    }

    private void ChromeRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => UpdateDragRegion();

    private void UpdateDragRegion()
    {
        if (closing || captionSource is null || dragArea is null || chromeRoot is null) return;
        var scale = chromeRoot.RasterizationScale;
        captionSource.SetRegionRects(NonClientRegionKind.Caption, [
            new Windows.Graphics.RectInt32(0, 0,
                (int)Math.Floor(dragArea.ActualWidth * scale), (int)Math.Floor(dragArea.ActualHeight * scale))
        ]);
    }

    private void ShowFromTray()
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.Restore();
        AppWindow.Show();
        Activate();
    }

    private void SaveSettings()
    {
        if (!settingsValid) return;
        try
        {
            new HelperSettings { DuckPercent = audio.DuckPercent, AllowedApps = allowed.Order().ToArray() }.Save(SettingsPath);
            activity.Add($"Settings saved: ducked volume {audio.DuckPercent}%; {allowed.Count} apps opted in.");
        }
        catch (Exception error)
        {
            Stop("Settings not saved; forwarding stopped.");
            Report("Could not save settings; changes are not persistent", error);
        }
    }

    private void Shutdown()
    {
        if (closing) return;
        closing = true;
        if (chromeRoot is not null) chromeRoot.Changed -= ChromeRootChanged;
        settingsTimer.Stop();
        SaveSettings();
        Stop("Stopped.");
        audioTimer.Stop();
        audio.Dispose();
        tray?.Dispose();
        tray = null;
        if (audio.Status.Contains("restoration failed", StringComparison.Ordinal))
            NativeTray.ShowError(audio.Status);
    }

    private void Exit()
    {
        Shutdown();
        Close();
    }

    private void RefreshLog()
    {
        var snapshot = activity.Snapshot();
        if (snapshot.Version == logVersion) return;
        var atBottom = logScroll.VerticalOffset >= logScroll.ScrollableHeight - 2;
        var offset = logScroll.VerticalOffset;
        logVersion = snapshot.Version;
        logView.Text = snapshot.Text;
        logView.UpdateLayout();
        logScroll.ChangeView(null, atBottom ? logScroll.ScrollableHeight : offset, null, true);
    }

    private void Report(string operation, Exception error)
    {
        status.Text = $"{operation} ({error.GetType().Name}, 0x{error.HResult:X8}). No notification contents logged.";
        activity.Add(status.Text);
    }

    private async Task StartAsync()
    {
        access.IsEnabled = false;
        try
        {
            var permission = await listener.RequestAccessAsync();
            if (closing) return;
            activity.Add($"Windows notification permission: {permission}.");
            if (permission != UserNotificationListenerAccessStatus.Allowed)
            {
                status.Text = $"Access {permission}. Enable ZoneXM in Windows Settings > Privacy & security > Notifications, then try again.";
                return;
            }
            bridge.Reset();
            observed.Clear();
            observedPrimed = false;
            activity.Add("Notification forwarding started; baselining current Notification Center entries.");
            running = true;
            failures = 0;
            retryAt = default;
            epoch++;
            pause.IsEnabled = true;
            timer.Start();
            await PollAsync();
        }
        catch (Exception error)
        {
            Stop("Stopped.");
            Report("Windows notification access failed; check package registration and permission", error);
        }
        finally { if (!closing) access.IsEnabled = !running; }
    }

    private void Stop(string message)
    {
        running = false;
        epoch++;
        timer.Stop();
        pause.IsEnabled = false;
        access.IsEnabled = settingsValid && !closing;
        status.Text = message;
        activity.Add(message);
        try { bridge.Clear(); }
        catch (Exception error) { Report("Could not clear banner file (it expires within 8 seconds)", error); }
    }

    private void AddApp(string id, string name)
    {
        if (!listed.Add(id)) return;
        var label = new StackPanel { Spacing = 2 };
        label.Children.Add(new TextBlock { Text = name, TextWrapping = TextWrapping.Wrap });
        label.Children.Add(new TextBlock { Text = id, Style = (Style)Application.Current.Resources["CompanionTechnicalStyle"] });
        var checkbox = new CheckBox
        {
            Content = label,
            IsChecked = allowed.Contains(id),
            Margin = new Thickness(0, 7, 0, 0)
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(checkbox, $"{name} ({id})");
        RoutedEventHandler updateApp = (_, _) =>
        {
            if (checkbox.IsChecked == true) allowed.Add(id); else allowed.Remove(id);
            try
            {
                new HelperSettings { DuckPercent = audio.DuckPercent, AllowedApps = allowed.Order().ToArray() }.Save(SettingsPath);
                // A new baseline prevents unchecking/rechecking from replaying history.
                epoch++;
                bridge.Reset();
                observed.Clear();
                observedPrimed = false;
                if (running) bridge.Publish(DateTimeOffset.UtcNow); else bridge.Clear();
                activity.Add($"App consent saved: {NotificationBridge.Clean(id)} {(allowed.Contains(id) ? "opted in" : "disabled")}; history baseline reset.");
            }
            catch (Exception error)
            {
                Stop("Stopped.");
                Report("Could not save app filter; forwarding stopped", error);
            }
        };
        checkbox.Checked += updateApp;
        checkbox.Unchecked += updateApp;
        apps.Children.Add(checkbox);
    }

    private async Task PollAsync()
    {
        if (busy || !running || closing || DateTimeOffset.UtcNow < retryAt) return;
        busy = true;
        var generation = epoch;
        try
        {
            if (listener.GetAccessStatus() != UserNotificationListenerAccessStatus.Allowed)
            {
                Stop("Windows notification permission was revoked. Forwarding stopped.");
                return;
            }
            var notifications = await listener.GetNotificationsAsync(NotificationKinds.Toast).AsTask()
                .WaitAsync(TimeSpan.FromSeconds(5));
            if (!running || closing || generation != epoch) return;
            if (listener.GetAccessStatus() != UserNotificationListenerAccessStatus.Allowed)
            {
                Stop("Windows notification permission was revoked. Forwarding stopped.");
                return;
            }
            var notices = new List<Notice>();
            var currentObserved = new HashSet<(string App, uint Id, long Created)>();
            var skipped = 0;
            foreach (var notification in notifications)
            {
                try
                {
                    var id = notification.AppInfo.AppUserModelId;
                    var name = notification.AppInfo.DisplayInfo.DisplayName;
                    AddApp(id, name);
                    var key = (id, notification.Id, notification.CreationTime.UtcTicks);
                    currentObserved.Add(key);
                    var newEntry = observedPrimed && !observed.Contains(key);
                    if (!allowed.Contains(id))
                    {
                        if (newEntry) activity.Add($"Notification ignored: app={NotificationBridge.Clean(id)}, id={notification.Id}, app not opted in.");
                        continue;
                    }
                    var binding = notification.Notification.Visual.GetBinding(KnownNotificationBindings.ToastGeneric);
                    if (binding is null)
                    {
                        if (newEntry) activity.Add($"Notification ignored: app={NotificationBridge.Clean(id)}, id={notification.Id}, no ToastGeneric text binding.");
                        continue;
                    }
                    var text = binding.GetTextElements().Select(t => t.Text).ToArray();
                    if (text.Length == 0)
                    {
                        if (newEntry) activity.Add($"Notification ignored: app={NotificationBridge.Clean(id)}, id={notification.Id}, no text elements.");
                        continue;
                    }
                    notices.Add(new Notice(notification.Id, notification.CreationTime, id, name,
                        text[0], string.Join(" / ", text.Skip(1))));
                }
                catch (Exception error)
                {
                    skipped++;
                    Report("A notification could not be read", error);
                }
            }
            var now = DateTimeOffset.UtcNow;
            observed = currentObserved;
            observedPrimed = true;
            bridge.Observe(notices, allowed, now);
            bridge.Publish(now);
            if (failures > 0)
            {
                activity.Add($"Notification polling recovered after {failures} failed attempt(s).");
                failures = 0;
            }
            if (skipped == 0)
                status.Text = $"Watching Notification Center. {listed.Count} apps seen; {allowed.Count} opted in. Unchecked apps never forward. History is not replayed.";
        }
        catch (Exception error)
        {
            if (!running || closing || generation != epoch) return;
            failures++;
            // Notification Center reads can fail transiently (e.g. 0x80070005); keep the
            // consent baseline and retry with backoff instead of silently stopping.
            var delay = TimeSpan.FromSeconds(Math.Min(60, 5 << Math.Min(failures - 1, 4)));
            retryAt = DateTimeOffset.UtcNow + delay;
            if (failures <= 3 || failures % 20 == 0)
                Report($"Notification polling failed (attempt {failures}); retrying in {delay.TotalSeconds:0}s", error);
            else status.Text = $"Notification polling failing (attempt {failures}); retrying in {delay.TotalSeconds:0}s.";
        }
        finally { busy = false; }
    }
}
