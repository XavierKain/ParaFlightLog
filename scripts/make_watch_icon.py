#!/usr/bin/env python3
"""Génère l'icône ronde de l'app Watch (et la complication .appLauncher).

watchOS masque toujours l'icône en cercle : la composition tient donc dans le
cercle inscrit, sans texte, avec un glyphe d'aile lisible jusqu'à ~40 px.

Usage: python3 scripts/make_watch_icon.py
Sortie: "ParaFlightLogWatch Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" (1024, sans alpha)
        + scripts/preview_watch_icon.png (rendu circulaire multi-tailles pour contrôle)
"""

import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024          # taille finale
SS = 4            # suréchantillonnage
W = S * SS
CX = W // 2

# --- Palette de marque -------------------------------------------------------
BG_CORE = (26, 84, 148)     # bleu ciel profond au centre
BG_EDGE = (5, 13, 26)       # bleu nuit sur les bords
CANOPY_TOP = (233, 251, 255)
CANOPY_BOT = (44, 168, 232)
LINES = (176, 226, 246)
GLOW = (58, 196, 240)


def s(v: float) -> float:
    """Coordonnée exprimée en unités 1024 -> pixels suréchantillonnés."""
    return v * SS


def radial_background() -> Image.Image:
    y, x = np.mgrid[0:W, 0:W].astype(np.float32)
    # foyer légèrement haut/gauche pour un éclairage naturel
    d = np.hypot(x - W * 0.42, y - W * 0.34) / (W * 0.78)
    t = np.clip(d, 0.0, 1.0) ** 1.15
    core = np.array(BG_CORE, np.float32)
    edge = np.array(BG_EDGE, np.float32)
    img = core[None, None, :] * (1 - t)[..., None] + edge[None, None, :] * t[..., None]
    return Image.fromarray(img.astype(np.uint8), "RGB")


def vertical_gradient(top, bottom, y0: float, y1: float) -> Image.Image:
    """Dégradé vertical calé sur [y0, y1] (unités 1024) pour qu'il porte vraiment."""
    ramp = np.clip((np.arange(W, dtype=np.float32) - s(y0)) / (s(y1) - s(y0)), 0, 1)[:, None]
    a = np.array(top, np.float32)[None, :]
    b = np.array(bottom, np.float32)[None, :]
    col = a * (1 - ramp) + b * ramp                      # (W, 3)
    return Image.fromarray(np.repeat(col[:, None, :], W, axis=1).astype(np.uint8), "RGB")


# --- Géométrie de l'aile -----------------------------------------------------
# Planforme allongée (parapente) plutôt que dôme (parachute) : a >> b.
A_OUT, B_OUT = 358.0, 210.0     # demi-axes du bord d'attaque
CY_E = 456.0                    # centre de l'ellipse porteuse
THICK = 74.0                    # corde de l'aile au centre
THETA_MAX = math.radians(82)
PILOT = (512.0, 746.0)
ATTACH_L, ATTACH_R = (500.0, 710.0), (524.0, 710.0)


def arc(a: float, b: float, n: int = 240):
    return [
        (CX + s(a * math.sin(t)), s(CY_E - b * math.cos(t)))
        for t in np.linspace(-THETA_MAX, THETA_MAX, n)
    ]


def canopy_mask() -> Image.Image:
    outer = arc(A_OUT, B_OUT)
    inner = arc(A_OUT - THICK, B_OUT - THICK)[::-1]
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).polygon(outer + inner, fill=255)
    return m


def draw_lines(draw: ImageDraw.ImageDraw) -> None:
    a_in, b_in = A_OUT - THICK, B_OUT - THICK
    for deg in (-72, -48, -24, 24, 48, 72):
        t = math.radians(deg)
        x = CX + s(a_in * math.sin(t))
        y = s(CY_E - b_in * math.cos(t))
        ax, ay = ATTACH_L if deg < 0 else ATTACH_R
        draw.line([(x, y), (s(ax), s(ay))], fill=LINES + (215,), width=int(s(6.5)))


def draw_pilot(draw: ImageDraw.ImageDraw) -> None:
    px, py = PILOT
    hw, hh, r = s(30), s(37), s(26)
    draw.rounded_rectangle(
        [px * SS - hw, py * SS - hh, px * SS + hw, py * SS + hh],
        radius=r, fill=(255, 255, 255, 255),
    )


def build() -> Image.Image:
    base = radial_background().convert("RGBA")
    mask = canopy_mask()

    # halo cyan sous l'aile pour décoller du fond
    glow = Image.new("RGBA", (W, W), GLOW + (0,))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(s(26))).point(lambda v: int(v * 0.55)))
    base = Image.alpha_composite(base, glow)

    # suspentes + pilote
    overlay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    draw_lines(d)
    draw_pilot(d)
    base = Image.alpha_composite(base, overlay)

    # voile avec dégradé calé sur sa propre hauteur
    canopy = vertical_gradient(
        CANOPY_TOP, CANOPY_BOT, CY_E - B_OUT, CY_E - (B_OUT - THICK) * math.cos(THETA_MAX)
    ).convert("RGBA")
    canopy.putalpha(mask)
    base = Image.alpha_composite(base, canopy)

    return base.convert("RGB").resize((S, S), Image.LANCZOS)


def circular_preview(icon: Image.Image) -> Image.Image:
    sizes = [196, 108, 88, 44]
    pad, gap = 24, 24
    width = pad * 2 + sum(sizes) + gap * (len(sizes) - 1)
    height = pad * 2 + sizes[0]
    sheet = Image.new("RGB", (width, height), (18, 18, 20))
    x = pad
    for sz in sizes:
        thumb = icon.resize((sz, sz), Image.LANCZOS).convert("RGBA")
        m = Image.new("L", (sz * 4, sz * 4), 0)
        ImageDraw.Draw(m).ellipse([0, 0, sz * 4 - 1, sz * 4 - 1], fill=255)
        thumb.putalpha(m.resize((sz, sz), Image.LANCZOS))
        sheet.paste(thumb, (x, pad + (sizes[0] - sz) // 2), thumb)
        x += sz + gap
    return sheet


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icon = build()
    out = os.path.join(
        root, "ParaFlightLogWatch Watch App", "Assets.xcassets",
        "AppIcon.appiconset", "AppIcon.png",
    )
    icon.save(out)
    preview = os.path.join(root, "scripts", "preview_watch_icon.png")
    circular_preview(icon).save(preview)
    print("écrit:", out)
    print("aperçu:", preview)
