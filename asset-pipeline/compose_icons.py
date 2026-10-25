"""Build the two inventory icons from rendered + vanilla artwork.

  python compose_icons.py

Molotov: the Blender render, canted right to match the vanilla bottle's lean.
Kit:     the vanilla vodka icon with the vanilla bandage laid across it like a
         plus sign - both straight from the game's own textures, only rotated
         and scaled, so the kit reads as "bottle + bandage".
"""

import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
VANILLA = os.path.join(OUT, "vanilla")

MOLOTOV_RAW = os.path.join(OUT, "T_MolotovIcon_raw.png")
MOLOTOV_OUT = os.path.join(OUT, "T_MolotovIcon.png")
KIT_OUT = os.path.join(OUT, "T_MolotovKitIcon.png")
VODKA = os.path.join(VANILLA, "T_cns_cossacks_vodka_01.png")
BANDAGE = os.path.join(VANILLA, "T_cns_bandage_01.png")

CANT = -10  # degrees; vanilla bottle icons lean right
SIZE = 512


def trim(img):
    """Crop to the visible pixels so scaling is not wasted on empty alpha."""
    box = img.split()[-1].getbbox()
    return img.crop(box) if box else img


def fit(img, box_w, box_h):
    scale = min(box_w / img.width, box_h / img.height)
    return img.resize(
        (max(1, round(img.width * scale)), max(1, round(img.height * scale))),
        Image.LANCZOS,
    )


def place(canvas, art, cx, cy):
    """Centre art on a fraction of the canvas, clamped so nothing clips off."""
    x = int(SIZE * cx) - art.width // 2
    y = int(SIZE * cy) - art.height // 2
    x = max(0, min(x, SIZE - art.width))
    y = max(0, min(y, SIZE - art.height))
    canvas.alpha_composite(art, (x, y))


def build_molotov():
    raw = trim(Image.open(MOLOTOV_RAW).convert("RGBA"))
    # expand=True keeps the corners from being clipped by the rotation
    canted = trim(raw.rotate(CANT, resample=Image.BICUBIC, expand=True))
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    place(canvas, fit(canted, int(SIZE * 0.78), int(SIZE * 0.88)), 0.5, 0.5)
    canvas.save(MOLOTOV_OUT)
    print(f"COMPOSED {MOLOTOV_OUT} {canvas.size}")


def build_kit():
    bottle = trim(Image.open(VODKA).convert("RGBA"))
    bandage = trim(Image.open(BANDAGE).convert("RGBA"))

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # bottle upright and left of centre, leaving room for the cross-piece
    place(canvas, fit(bottle, int(SIZE * 0.46), int(SIZE * 0.84)), 0.36, 0.48)

    # bandage laid across the bottle's lower half to read as "bottle + bandage"
    r = trim(bandage.rotate(-35, resample=Image.BICUBIC, expand=True))
    place(canvas, fit(r, int(SIZE * 0.46), int(SIZE * 0.46)), 0.63, 0.66)

    canvas.save(KIT_OUT)
    print(f"COMPOSED {KIT_OUT} {canvas.size}")


build_molotov()
build_kit()
print("COMPOSE_DONE")
