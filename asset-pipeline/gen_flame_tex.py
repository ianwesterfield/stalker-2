# Generate flame material textures: T_RagFlame (shaped color+alpha gradient)
# and T_FlameNoise (tileable value noise for UV distortion / flicker).
# Run: blender -b -P gen_flame_tex.py
import bpy
import numpy as np
import os

OUT_DIR = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"
os.makedirs(OUT_DIR, exist_ok=True)


def save_png(name, rgba):  # rgba float32 HxWx4, row 0 = bottom (Blender order)
    h, w = rgba.shape[:2]
    img = bpy.data.images.new(name, width=w, height=h, alpha=True)
    img.pixels.foreach_set(rgba.astype(np.float32).ravel())
    img.filepath_raw = os.path.join(OUT_DIR, name + ".png")
    img.file_format = "PNG"
    img.save()
    print(f"wrote {img.filepath_raw}")


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# --- T_RagFlame: teardrop heat gradient, color ramp baked in ---
S = 512
v, u = np.meshgrid(np.linspace(0, 1, S), np.linspace(0, 1, S), indexing="ij")

# half-width profile: quick swell off the base, concave taper to a point tip
w = 0.48 * smoothstep(0.0, 0.3, v) ** 0.45 * np.clip(1.0 - v, 0, 1) ** 1.35
w = np.maximum(w, 1e-4)
d = np.abs(u - 0.5) / w
core = np.clip(1.0 - d, 0.0, 1.0)

fade_in = smoothstep(0.0, 0.06, v)  # roots soften into the rag
fade_out = 1.0 - smoothstep(0.96, 1.0, v)
heat = core**1.4 * fade_in * fade_out

# color ramp: deep red edge -> orange -> yellow -> white-hot core
r = np.clip(heat * 3.0, 0, 1)
g = np.clip(heat * 1.8 - 0.25, 0, 1)
b = np.clip(heat * 2.6 - 1.75, 0, 1)
alpha = smoothstep(0.03, 0.55, heat)

save_png("T_RagFlame", np.stack([r, g, b, alpha], axis=-1))

# --- T_FlameNoise: tileable multi-octave value noise ---
N = 256
rng = np.random.default_rng(7)
noise = np.zeros((N, N))
amp_sum = 0.0
for octave, (cells, amp) in enumerate([(4, 1.0), (8, 0.5), (16, 0.25), (32, 0.125)]):
    grid = rng.random((cells, cells))
    gy, gx = np.meshgrid(
        np.linspace(0, cells, N, endpoint=False),
        np.linspace(0, cells, N, endpoint=False),
        indexing="ij",
    )
    y0, x0 = gy.astype(int), gx.astype(int)
    fy, fx = gy - y0, gx - x0
    fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)  # smoothstep interp
    y1, x1 = (y0 + 1) % cells, (x0 + 1) % cells  # wrap = tileable
    n = (
        grid[y0, x0] * (1 - fy) * (1 - fx)
        + grid[y1, x0] * fy * (1 - fx)
        + grid[y0, x1] * (1 - fy) * fx
        + grid[y1, x1] * fy * fx
    )
    noise += n * amp
    amp_sum += amp
noise /= amp_sum
noise = (noise - noise.min()) / (noise.max() - noise.min())

save_png("T_FlameNoise", np.stack([noise, noise, noise, np.ones_like(noise)], axis=-1))


# --- T_RagCloth: woven linen, fuel-stained, charred toward the flame end ---
def value_noise(size, octaves, seed):
    rng = np.random.default_rng(seed)
    out = np.zeros((size, size))
    total = 0.0
    for cells, amp in octaves:
        grid = rng.random((cells, cells))
        gy, gx = np.meshgrid(
            np.linspace(0, cells, size, endpoint=False),
            np.linspace(0, cells, size, endpoint=False),
            indexing="ij",
        )
        y0, x0 = gy.astype(int), gx.astype(int)
        fy, fx = gy - y0, gx - x0
        fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
        y1, x1 = (y0 + 1) % cells, (x0 + 1) % cells
        out += amp * (
            grid[y0, x0] * (1 - fy) * (1 - fx)
            + grid[y1, x0] * fy * (1 - fx)
            + grid[y0, x1] * (1 - fy) * fx
            + grid[y1, x1] * fy * fx
        )
        total += amp
    out /= total
    return (out - out.min()) / (out.max() - out.min())


C = 512
v, u = np.meshgrid(np.linspace(0, 1, C), np.linspace(0, 1, C), indexing="ij")
weave = (0.5 + 0.5 * np.sin(u * 2 * np.pi * 52)) * (
    0.5 + 0.5 * np.sin(v * 2 * np.pi * 52)
)
stain = value_noise(C, [(5, 1.0), (13, 0.5), (29, 0.25)], 11)
base = np.array([0.42, 0.36, 0.27])  # worn linen
shade = (0.72 + 0.28 * weave) * (0.65 + 0.35 * stain)
# numpy v=1 = UE V=0 = the attach end next to the flame: charred
soot = 1.0 - 0.8 * smoothstep(0.55, 0.98, v * (0.75 + 0.25 * stain))
rgbc = base[None, None, :] * (shade * soot)[..., None]
rgbc[..., 2] *= 0.9  # fuel yellows it slightly
save_png("T_RagCloth", np.concatenate([rgbc, np.ones((C, C, 1))], axis=-1))
print("done")
