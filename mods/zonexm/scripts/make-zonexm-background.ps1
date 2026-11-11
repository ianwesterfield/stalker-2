[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\..\build\zonexm-art'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
public static class ZoneXMArt {
  static double Hash(int x, int y, int seed) {
    unchecked {
      uint h = (uint)(x * 374761393 + y * 668265263 + seed * 1442695041);
      h = (h ^ (h >> 13)) * 1274126177u;
      h ^= h >> 16;
      return (h & 0xFFFFFF) / 16777215.0;
    }
  }
  static double Clamp(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  static double Step(double a, double b, double v) { double t = Clamp((v - a) / (b - a)); return t * t * (3 - 2 * t); }
  static double Lerp(double a, double b, double t) { return a + (b - a) * t; }
  static double Value(double x, double y, int seed) {
    int xi = (int)Math.Floor(x), yi = (int)Math.Floor(y);
    double tx = x - xi, ty = y - yi;
    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
    double a = Hash(xi, yi, seed), b = Hash(xi + 1, yi, seed), c = Hash(xi, yi + 1, seed), d = Hash(xi + 1, yi + 1, seed);
    return a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty;
  }
  static double Fbm(double x, double y, int seed, int octaves) {
    double sum = 0, amp = 0.5, freq = 1, norm = 0;
    for (int i = 0; i < octaves; i++) { sum += amp * Value(x * freq, y * freq, seed + i * 17); norm += amp; amp *= 0.5; freq *= 2; }
    return sum / norm;
  }
  static double RoundBox(double u, double v, double hw, double hh, double r) {
    double qx = Math.Abs(u) - hw + r, qy = Math.Abs(v) - hh + r;
    double ox = Math.Max(qx, 0), oy = Math.Max(qy, 0);
    return Math.Sqrt(ox * ox + oy * oy) + Math.Min(Math.Max(qx, qy), 0) - r;
  }
  static void Put(byte[] px, int i, double r, double g, double b, double a) {
    px[i] = (byte)(Clamp(b / 255) * 255); px[i + 1] = (byte)(Clamp(g / 255) * 255);
    px[i + 2] = (byte)(Clamp(r / 255) * 255); px[i + 3] = (byte)(Clamp(a) * 255);
  }

  // Weathered gray concrete/steel: low-frequency mottling, water stains, faint brushing, vignette.
  public static byte[] Background(int w, int h) {
    var px = new byte[w * h * 4];
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) {
        double n = Fbm(x / 180.0, y / 180.0, 1, 5);
        double stain = Step(0.5, 0.85, Fbm(x / 140.0, y / 140.0, 7, 4));
        double brush = Fbm(x / 400.0, y / 2.5, 3, 2);
        double grain = Hash(x, y, 99);
        double dx = (x - w / 2.0) / (w / 2.0), dy = (y - h / 2.0) / (h / 2.0);
        double vignette = 1 - 0.22 * (dx * dx + dy * dy);
        double g = (80 + (n - 0.5) * 30 + (brush - 0.5) * 6 + (grain - 0.5) * 9 - stain * 10) * vignette;
        Put(px, (y * w + x) * 4, g + 2, g + 2, g, 1);
      }
    return px;
  }

  // Rusted, chipped radiation warning plate with bolt-hole rust streaks and a soft drop shadow.
  public static byte[] Sign(int size, double degrees, bool dropShadow, double extent) {
    var px = new byte[size * size * 4];
    double half = size / 2.0, hw = size * extent / 2, cr = size * 0.04;
    double angle = degrees * Math.PI / 180, ca = Math.Cos(angle), sa = Math.Sin(angle);
    double r1 = hw * 0.14, bolt = hw - size * 0.055;
    double[,] bolts = { { -bolt, -bolt }, { bolt, -bolt }, { -bolt, bolt }, { bolt, bolt } };
    for (int y = 0; y < size; y++)
      for (int x = 0; x < size; x++) {
        double ox = x + 0.5 - half, oy = y + 0.5 - half;
        double u = ox * ca + oy * sa, v = -ox * sa + oy * ca;
        double edgeNoise = (Fbm(u / 22.0, v / 22.0, 5, 3) - 0.5) * 7;
        double d = RoundBox(u, v, hw, hw, cr) + edgeNoise;
        double cover = Clamp(0.5 - d);
        double shadowD = RoundBox(u - size * 0.015, v - size * 0.022, hw, hw, cr);
        double shadow = dropShadow ? Clamp((-shadowD + 14) / 28) * 0.5 : 0;
        int i = (y * size + x) * 4;
        if (cover <= 0) { Put(px, i, 0, 0, 0, shadow); continue; }

        double rn = Fbm(u / 38.0, v / 38.0, 11, 5), fine = Hash(x, y, 77);
        double rr = Lerp(64, 170, rn) + (fine - 0.5) * 18, rg = Lerp(30, 84, rn) + (fine - 0.5) * 10, rb = Lerp(14, 30, rn);

        double grime = Fbm(u / 60.0, v / 60.0, 21, 4);
        double pr = 228, pg = 178, pb = 26;
        double ink = 0;
        double band = RoundBox(u, v, hw - size * 0.045, hw - size * 0.045, cr * 0.7);
        ink = Math.Max(ink, Clamp(size * 0.012 + 0.5 - Math.Abs(band)));
        double tr = Math.Sqrt(u * u + v * v);
        ink = Math.Max(ink, Clamp(r1 - tr + 0.5));
        double theta = Math.Atan2(-v, u) * 180 / Math.PI;
        double nearest = 180;
        foreach (double c in new double[] { 30, 150, 270 }) {
          double delta = Math.Abs(((theta - c) % 360 + 540) % 360 - 180);
          if (delta < nearest) nearest = delta;
        }
        double radial = Clamp(tr - 1.5 * r1 + 0.5) * Clamp(5 * r1 - tr + 0.5);
        double angular = Clamp((30 - nearest) * Math.PI / 180 * tr + 0.5);
        ink = Math.Max(ink, radial * angular);
        double shade = 0.78 + 0.28 * grime;
        pr = Lerp(pr * shade, 24, ink); pg = Lerp(pg * shade, 23, ink); pb = Lerp(pb * shade, 20, ink);

        double streak = 0;
        for (int b = 0; b < 4; b++) {
          double bx = bolts[b, 0], by = bolts[b, 1];
          if (v <= by) continue;
          double dy = v - by, width = 7 + dy * 0.07;
          double dx = u - bx + (Fbm(v / 30.0, b * 7.3, 41, 2) - 0.5) * 16;
          streak += Math.Exp(-dx * dx / (2 * width * width)) * Math.Exp(-dy / 210) * (0.55 + 0.45 * Fbm(u / 6.0, v / 40.0, 43 + b, 3));
        }
        streak += Step(0.62, 0.82, Fbm(u / 11.0, v / 150.0, 51, 3)) * 0.45 * Clamp((v + hw) / (2 * hw));
        streak = Clamp(streak * 0.9);
        pr = Lerp(pr, 122, streak); pg = Lerp(pg, 56, streak); pb = Lerp(pb, 20, streak);

        double inside = -d;
        double boltRust = 0;
        for (int b = 0; b < 4; b++) {
          double bdx = u - bolts[b, 0], bdy = v - bolts[b, 1];
          boltRust = Math.Max(boltRust, Math.Exp(-Math.Sqrt(bdx * bdx + bdy * bdy) / 22));
        }
        double threshold = 0.68 - 0.24 * Math.Exp(-inside / 34) - 0.2 * boltRust;
        double chip = Step(threshold, threshold + 0.035, Fbm(u / 30.0, v / 30.0, 31, 5));
        double r = Lerp(pr, rr, chip), g = Lerp(pg, rg, chip), bl = Lerp(pb, rb, chip);

        double scratch = Step(0.82, 0.86, Fbm(u / 220.0 + v / 900.0, v / 3.2, 61, 3)) * (1 - chip);
        r = Lerp(r, 160, scratch * 0.7); g = Lerp(g, 152, scratch * 0.7); bl = Lerp(bl, 140, scratch * 0.7);

        for (int b = 0; b < 4; b++) {
          double bdx = u - bolts[b, 0], bdy = v - bolts[b, 1], bd = Math.Sqrt(bdx * bdx + bdy * bdy);
          double head = Clamp(size * 0.022 - bd + 0.5);
          if (head <= 0) continue;
          double metal = 120 - bdx * 2.2 - bdy * 2.2 + (Hash(x, y, 5) - 0.5) * 20;
          double rim = Clamp(bd - size * 0.017);
          metal = Lerp(metal, 40, rim);
          r = Lerp(r, metal + 8, head); g = Lerp(g, metal, head); bl = Lerp(bl, metal - 6, head);
        }

        double light = 1.06 - 0.12 * ((u + v) / (2 * hw));
        double bevel = 1 - 0.3 * Clamp(1 - inside / 5);
        r *= light * bevel; g *= light * bevel; bl *= light * bevel;
        double alpha = cover + shadow * (1 - cover);
        Put(px, i, r * cover / alpha, g * cover / alpha, bl * cover / alpha, alpha);
      }
    return px;
  }
}
'@

function Save-Pixels([byte[]]$pixels, [int]$width, [int]$height, [string]$path) {
  $bmp = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $rect = [Drawing.Rectangle]::new(0, 0, $width, $height)
    $data = $bmp.LockBits($rect, [Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    try { [Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length) }
    finally { $bmp.UnlockBits($data) }
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  }
  finally { $bmp.Dispose() }
}

$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
Save-Pixels ([ZoneXMArt]::Background(1600, 1000)) 1600 1000 (Join-Path $OutputDirectory 'Background.png')
Save-Pixels ([ZoneXMArt]::Sign(640, -5, $true, 0.78)) 640 640 (Join-Path $OutputDirectory 'RadiationSign.png')
Save-Pixels ([ZoneXMArt]::Sign(512, 0, $false, 0.96)) 512 512 (Join-Path $OutputDirectory 'RadiationIcon.png')
Write-Host "Wrote Background.png, RadiationSign.png and RadiationIcon.png to $OutputDirectory"
