#!/usr/bin/env python3
"""Extract a menubar template icon (black + alpha) from the hummingbird art.

Pipeline: border flood-fill for true background (keeps the white belly as
bird), geometric removal of the hibiscus corner, largest connected component
(drops strays), morphological opening to dissolve thin claws, blur+threshold
for smooth edges. Output: black+alpha PNG + preview strips.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

SRC = sys.argv[1] if len(sys.argv) > 1 else "/Users/renzof/Library/Containers/com.apple.GenerativePlaygroundApp/Data/tmp/PlaygroundImage.jpeg"
OUT_TEMPLATE = sys.argv[2] if len(sys.argv) > 2 else "menubar-template.png"
OUT_PREVIEW = sys.argv[3] if len(sys.argv) > 3 else "bird-preview.png"
BG_THRESHOLD = 235

img = Image.open(SRC).convert("RGB")
W, H = img.size
gray = np.asarray(img.convert("L"), dtype=np.uint8)

# --- background: flood from borders over near-white pixels (low-res flood) ---
LO = 400
lo = np.asarray(img.resize((LO, LO), Image.BILINEAR).convert("L"), dtype=np.uint8)
bg_lo = lo > BG_THRESHOLD
reached = np.zeros_like(bg_lo)
reached[0, :] = bg_lo[0, :]
reached[-1, :] = bg_lo[-1, :]
reached[:, 0] = bg_lo[:, 0]
reached[:, -1] = bg_lo[:, -1]
while True:
    grown = reached.copy()
    grown[1:, :] |= reached[:-1, :]
    grown[:-1, :] |= reached[1:, :]
    grown[:, 1:] |= reached[:, :-1]
    grown[:, :-1] |= reached[:, 1:]
    grown &= bg_lo
    if (grown == reached).all():
        break
    reached = grown

# upscale the reached-background map, combine with a high-res white test
bg_up = np.asarray(Image.fromarray((reached * 255).astype(np.uint8)).resize((W, H), Image.NEAREST)) > 127
background = bg_up & (gray > 200)
mask = ~background  # foreground candidate

# --- geometric removal: hibiscus corner (bottom-left) ---
yy, xx = np.mgrid[0:H, 0:W]
mask[(xx < 0.42 * W) & (yy > 0.55 * H)] = False

# --- largest connected component (4-neighbour BFS on a downsample, then hi mask)
LOW = 300
mlow = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).resize((LOW, LOW), Image.NEAREST)) > 127
labels = np.zeros_like(mlow, dtype=np.int32)
current = 0
sizes = {}
for sy in range(LOW):
    for sx in range(LOW):
        if mlow[sy, sx] and labels[sy, sx] == 0:
            current += 1
            stack = [(sy, sx)]
            labels[sy, sx] = current
            count = 0
            while stack:
                cy, cx = stack.pop()
                count += 1
                for ny, nx in ((cy+1, cx), (cy-1, cx), (cy, cx+1), (cy, cx-1)):
                    if 0 <= ny < LOW and 0 <= nx < LOW and mlow[ny, nx] and labels[ny, nx] == 0:
                        labels[ny, nx] = current
                        stack.append((ny, nx))
            sizes[current] = count
if sizes:
    best = max(sizes, key=sizes.get)
    best_lo = labels == best
    best_up = np.asarray(Image.fromarray((best_lo * 255).astype(np.uint8)).resize((W, H), Image.NEAREST)) > 127
    mask &= best_up

# --- opening: dissolve thin claws (erode then dilate) ---
m = Image.fromarray((mask * 255).astype(np.uint8))
m = m.filter(ImageFilter.MinFilter(25))   # erode ~12px
m = m.filter(ImageFilter.MaxFilter(25))   # dilate back
mask = np.asarray(m) > 127

# --- smooth edges: blur + re-threshold ---
m = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(4))
mask = np.asarray(m) > 127

# --- crop to bounding box with margin ---
ys, xs = np.where(mask)
y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
pad = int(0.02 * max(y1 - y0, x1 - x0))
y0, y1 = max(0, y0 - pad), min(H, y1 + pad)
x0, x1 = max(0, x0 - pad), min(W, x1 + pad)

# --- template: black color, alpha = mask ---
template = np.zeros((y1 - y0, x1 - x0, 4), dtype=np.uint8)
template[..., 3] = mask[y0:y1, x0:x1].astype(np.uint8) * 255
Image.fromarray(template, "RGBA").save(OUT_TEMPLATE)

# --- preview: big + menubar-scale strips ---
bw, bh = x1 - x0, y1 - y0
canvas_w, canvas_h = 480, 360
prev = Image.new("RGB", (canvas_w, canvas_h), (245, 245, 245))
fit_h = 270
fit_w = int(bw * fit_h / bh)
if fit_w > 400:
    fit_w = 400
    fit_h = int(bh * 400 / bw)
bird = Image.new("RGBA", (fit_w, fit_h), (0, 0, 0, 0))
alpha = Image.fromarray(template[..., 3]).resize((fit_w, fit_h), Image.LANCZOS)
bird.putalpha(alpha)
black = Image.new("RGBA", (fit_w, fit_h), (0, 0, 0, 255))
black.putalpha(alpha)
prev.paste(black.convert("RGB"), ((canvas_w - fit_w) // 2, 40), black)
# menubar strips
strip_dark = Image.new("RGB", (200, 30), (26, 26, 26))
strip_light = Image.new("RGB", (220, 30), (235, 235, 235))
sw = 44
sh = int(sw * bh / bw)
small_a = Image.fromarray(template[..., 3]).resize((sw, sh), Image.LANCZOS)
small_black = Image.new("RGBA", (sw, sh), (255, 255, 255, 255))
small_black.putalpha(small_a)
strip_dark.paste(small_black.convert("RGB"), (12, (30 - sh) // 2), small_black)
strip_light.paste(small_black.convert("RGB"), (12, (30 - sh) // 2), small_black)
prev.paste(strip_dark, (20, canvas_h - 44))
prev.paste(strip_light, (240, canvas_h - 44))
prev.save(OUT_PREVIEW)
print(f"template {bw}x{bh} -> {OUT_TEMPLATE}; preview -> {OUT_PREVIEW}")
