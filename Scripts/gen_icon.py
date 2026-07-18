#!/usr/bin/env python3
"""Generate the Claude Proxy app icon SVG.

Flat black Apple-style squircle (continuous-corner superellipse) + a single
white Lucide `arrow-left-right` glyph, stroked exactly as Lucide renders it.
"""
import math

CANVAS = 1024
CENTER = CANVAS / 2

# --- Squircle: superellipse sampled to a smooth closed path -----------------
# 824x824 centred -> 100px transparent padding per side.
A = 412.0          # half-width/height (824 / 2)
N = 5.0            # exponent ~5 approximates Apple's continuous corner
STEPS = 720

def superellipse_path(a, n, steps):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(ct) ** (2 / n), ct)
        y = a * math.copysign(abs(st) ** (2 / n), st)
        pts.append((CENTER + x, CENTER + y))
    d = "M {:.3f} {:.3f} ".format(*pts[0])
    d += " ".join("L {:.3f} {:.3f}".format(px, py) for px, py in pts[1:])
    return d + " Z"

squircle = superellipse_path(A, N, STEPS)

# --- Glyph: Lucide `arrow-left-right` (24-unit viewBox, 2px stroke) ----------
# Source paths, verbatim from Lucide (ISC licensed). Each stays a separate
# <path> so its leading moveto is absolute (concatenating them turns the
# `m16 21` arrowhead into a relative move and flings it off-canvas).
# Glyph bbox is x:4..20, y:3..21 -> centred on (12,12), the viewBox centre.
LUCIDE = [
    "M8 3 4 7l4 4",
    "M4 7h16",
    "m16 21 4-4-4-4",
    "M20 17H4",
]
SCALE = 27.5                       # 16-unit content -> 440px (~43% of canvas)
OFFSET = CENTER - 12 * SCALE       # map lucide centre (12,12) -> canvas centre
STROKE = 2 * SCALE                 # 55px at 1024

glyph = "\n    ".join(f'<path d="{d}"/>' for d in LUCIDE)

svg = f'''<svg width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}" xmlns="http://www.w3.org/2000/svg">
  <!-- Flat black Apple-style squircle (continuous-corner superellipse) -->
  <path d="{squircle}" fill="#000000"/>
  <!-- Lucide arrow-left-right glyph, white, stroked as Lucide renders it -->
  <g transform="translate({OFFSET:.3f} {OFFSET:.3f}) scale({SCALE})"
     fill="none" stroke="#FFFFFF" stroke-width="2"
     stroke-linecap="round" stroke-linejoin="round">
    {glyph}
  </g>
</svg>
'''

with open("Assets/AppIcon.svg", "w") as f:
    f.write(svg)
print("wrote Assets/AppIcon.svg  (stroke={:.1f}px, glyph≈{:.0f}px)".format(STROKE, 16 * SCALE))
