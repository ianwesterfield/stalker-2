[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\build\zonexm-headings' }
$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

public static class ZoneXMHeadingArt {
    public static void RenderTitleWear(string wearPath, string output) {
        using (var wear = new Bitmap(wearPath))
        using (var bitmap = new Bitmap(wear.Width, wear.Height, PixelFormat.Format32bppArgb))
        using (var graphics = Graphics.FromImage(bitmap))
        using (var attributes = new ImageAttributes()) {
            var matrix = new ColorMatrix();
            matrix.Matrix33 = 3;
            attributes.SetColorMatrix(matrix);
            graphics.DrawImage(wear, new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                0, 0, wear.Width, wear.Height, GraphicsUnit.Pixel, attributes);
            bitmap.Save(output, ImageFormat.Png);
            Console.WriteLine("Title wear: {0}x{1}, 3x source alpha", bitmap.Width, bitmap.Height);
        }
    }

    public static void Render(string text, float size, string fontPath, string wearPath, string output, int seed) {
        const int scale = 4;
        using (var fonts = new PrivateFontCollection()) {
            fonts.AddFontFile(fontPath);
            using (var font = new Font(fonts.Families[0], size * scale, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var format = (StringFormat)StringFormat.GenericTypographic.Clone())
            using (var probe = new Bitmap(1, 1))
            using (var measure = Graphics.FromImage(probe))
            using (var wear = new Bitmap(wearPath)) {
                format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
                var bounds = measure.MeasureString(text, font, int.MaxValue, format);
                int width = (int)Math.Ceiling(bounds.Width) + 2;
                int height = (int)Math.Ceiling(font.GetHeight(measure)) + 2;
                using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb)) {
                    using (var graphics = Graphics.FromImage(bitmap))
                    using (var brush = new SolidBrush(Color.FromArgb(230, 173, 56))) {
                        graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                        graphics.DrawString(text, font, brush, 0, 0, format);
                    }
                    var rectangle = new Rectangle(0, 0, width, height);
                    var data = bitmap.LockBits(rectangle, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
                    int ink = 0, worn = 0;
                    try {
                        var pixels = new byte[data.Stride * height];
                        Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                        for (int pixelY = 0; pixelY < height; pixelY++) {
                            for (int pixelX = 0; pixelX < width; pixelX++) {
                                int offset = pixelY * data.Stride + pixelX * 4;
                                if (pixels[offset + 3] == 0) continue;
                                ink++;
                                double patina = wear.GetPixel((pixelX * wear.Width / width + seed * 37) % wear.Width,
                                    (pixelY * wear.Height / height + seed * 23) % wear.Height).A / 255.0;
                                double shade = 1 - 0.8 * patina;
                                for (int channel = 0; channel < 3; channel++)
                                    pixels[offset + channel] = (byte)Math.Round(pixels[offset + channel] * shade);
                                if (patina > 0.05) worn++;
                            }
                        }
                        Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
                    }
                    finally { bitmap.UnlockBits(data); }
                    if (ink == 0 || worn == 0) throw new InvalidOperationException("Heading has no glyphs or visible wear: " + text);
                    bitmap.Save(output, ImageFormat.Png);
                    Console.WriteLine("{0}: {1}x{2}, {3} glyph pixels, {4} textured pixels", text, width, height, ink, worn);
                }
            }
        }
    }
}
'@
$font = Join-Path $assets 'fonts\BarlowCondensed\BarlowCondensed-Bold.ttf'
$wear = Join-Path $assets 'companion\paint_wear_overlay_512.png'
[ZoneXMHeadingArt]::RenderTitleWear($wear, (Join-Path $OutputDirectory 'TitleWear.png'))
[ZoneXMHeadingArt]::Render('ZoneXM', 27, $font, $wear, (Join-Path $OutputDirectory 'AppName.png'), 1)
[ZoneXMHeadingArt]::Render('WINDOWS NOTIFICATION CENTER', 21, $font, $wear, (Join-Path $OutputDirectory 'Notifications.png'), 2)
[ZoneXMHeadingArt]::Render('ACTIVITY LOG', 21, $font, $wear, (Join-Path $OutputDirectory 'Activity.png'), 3)
[ZoneXMHeadingArt]::Render('APPS', 21, $font, $wear, (Join-Path $OutputDirectory 'Apps.png'), 4)