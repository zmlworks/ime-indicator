#!/usr/bin/env python3
"""Generate res/app.ico (orange rounded square with white 「あ」). Build-time helper only."""
from PIL import Image, ImageDraw, ImageFont
import os
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
here = os.path.dirname(os.path.abspath(__file__))
S = 256
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((8, 8, S - 9, S - 9), radius=48, fill=(226, 70, 31, 255), outline=(160, 46, 16, 255), width=10)
# index 0 of the TTC = Japanese variant (Noto Sans CJK JP)
font = ImageFont.truetype(FONT, 190, index=0)
bbox = d.textbbox((0, 0), "あ", font=font)
w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
d.text(((S - w) / 2 - bbox[0], (S - h) / 2 - bbox[1]), "あ", font=font, fill=(255, 255, 255, 255))
img.save(os.path.join(here, "app.ico"), sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (256, 256)])
img.save(os.path.join(here, "app_preview.png"))
