using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;

namespace ZoneXM.Notifications;

public sealed partial class TitleLogo : UserControl
{
  private LoadedImageSurface? surface;
  private CompositionSurfaceBrush? texture;
  private CompositionMaskBrush? mask;
  private SpriteVisual? visual;
  private XamlRoot? observedRoot;
  private bool queued;
  private bool failed;
  internal Action<string>? Log { get; init; }

  public TitleLogo()
  {
    InitializeComponent();
    Loaded += (_, _) =>
    {
      observedRoot = XamlRoot;
      if (observedRoot is not null) observedRoot.Changed += OnRootChanged;
      QueueRefresh();
    };
    Unloaded += (_, _) =>
    {
      if (observedRoot is not null) observedRoot.Changed -= OnRootChanged;
      observedRoot = null;
      Clear();
    };
    Lettering.SizeChanged += (_, _) => QueueRefresh();
  }

  internal TitleLogo(string text, double size) : this()
  {
    Lettering.Inlines.Clear();
    Lettering.Text = text;
    Lettering.FontSize = size;
    Lettering.Style = (Style)Application.Current.Resources["SubtitleTitleStyle"];
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Lettering, text);
  }

  private void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => QueueRefresh();

  private void QueueRefresh()
  {
    if (queued || failed || !IsLoaded) return;
    queued = DispatcherQueue.TryEnqueue(() =>
    {
      queued = false;
      if (!IsLoaded || failed || Lettering.ActualWidth <= 0 || Lettering.ActualHeight <= 0) return;
      try
      {
        if (visual is null)
        {
          var compositor = ElementCompositionPreview.GetElementVisual(WearLayer).Compositor;
          surface = LoadedImageSurface.StartLoadFromUri(new Uri("ms-appx:///Assets/Headings/TitleWear.png"));
          surface.LoadCompleted += OnTextureLoaded;
          texture = compositor.CreateSurfaceBrush(surface);
          texture.Stretch = CompositionStretch.Fill;
          mask = compositor.CreateMaskBrush();
          mask.Source = texture;
          visual = compositor.CreateSpriteVisual();
          visual.Brush = mask;
          ElementCompositionPreview.SetElementChildVisual(WearLayer, visual);
        }
        mask!.Mask = Lettering.GetAlphaMask();
        visual.Size = new Vector2((float)Lettering.ActualWidth, (float)Lettering.ActualHeight);
      }
      catch (Exception error)
      {
        failed = true;
        Clear();
        Log?.Invoke($"Title wear unavailable; using native lettering ({error.GetType().Name}, 0x{error.HResult:X8}).");
      }
    });
  }

  private void OnTextureLoaded(LoadedImageSurface sender, LoadedImageSourceLoadCompletedEventArgs args)
  {
    if (!ReferenceEquals(sender, surface) || args.Status == LoadedImageSourceLoadStatus.Success) return;
    failed = true;
    Clear();
    Log?.Invoke($"Title wear unavailable; using native lettering (texture load: {args.Status}).");
  }

  private void Clear()
  {
    if (visual is not null) ElementCompositionPreview.SetElementChildVisual(WearLayer, null);
    visual?.Dispose();
    mask?.Dispose();
    texture?.Dispose();
    if (surface is not null)
    {
      surface.LoadCompleted -= OnTextureLoaded;
      surface.Dispose();
    }
    visual = null;
    mask = null;
    texture = null;
    surface = null;
  }
}