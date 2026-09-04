#!/usr/bin/env python3
"""Regenerate the PWA icons in mobile/web/icons/ from the studio logo.

Run from the repo root:  python tools/make-web-icons.py   (needs Pillow)

The source logo is a 500x500 lock-up: a circular medallion above the words
"TANDAV / DANCE STUDIO". Only the **medallion** is used here. At 192px the
wordmark is roughly two pixels tall and reads as a smudge, so the icon keeps the
one element that survives being shrunk.

The medallion is lifted through a circular mask rather than a square crop,
because the source has tiny text either side of it at the same height that a
square crop drags in.

Two flavours are written, and the difference matters:

* `Icon-<n>.png`          — the artwork fills most of the square. Used as-is by
                            iOS (which rounds the corners itself) and by browser
                            tabs.
* `Icon-maskable-<n>.png` — Android may crop this to a circle, a squircle or a
                            rounded square of its choosing, and only the middle
                            80% is guaranteed to survive. So the medallion is
                            drawn much smaller, well inside that safe zone. It
                            looks over-padded on its own; that is correct.
"""

from PIL import Image, ImageDraw

SRC = 'mobile/assets/images/tandav_logo.jpeg'
OUT = 'mobile/web/icons'

# Measured from the source, not guessed: the gold disc's bounding box is
# (185,129)-(327,271) and the white braided ring around it adds ~17px.
CENTRE = (256, 190)
RADIUS = 88

BG = (11, 11, 14)          # TandavColors.background — matches index.html + manifest


def medallion() -> Image.Image:
    """The medallion alone, on transparency, as a square RGBA image."""
    src = Image.open(SRC).convert('RGB')
    cx, cy = CENTRE
    box = (cx - RADIUS, cy - RADIUS, cx + RADIUS, cy + RADIUS)
    disc = src.crop(box).convert('RGBA')
    mask = Image.new('L', disc.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, disc.size[0] - 1, disc.size[1] - 1), fill=255)
    disc.putalpha(mask)
    return disc


def write(disc: Image.Image, size: int, fill: float, name: str) -> None:
    """`fill` is the medallion diameter as a fraction of the icon's width."""
    canvas = Image.new('RGBA', (size, size), BG + (255,))
    d = max(1, round(size * fill))
    art = disc.resize((d, d), Image.LANCZOS)
    off = (size - d) // 2
    canvas.alpha_composite(art, (off, off))
    # Reduced to a 64-colour palette. The artwork is three colours plus the
    # anti-aliasing between them, but the source is a JPEG, so the flat dark
    # background arrives full of compression speckle that PNG cannot compress.
    # This takes the 512px icon from ~245 KB to ~67 KB with no visible change —
    # worth it when the whole point is a shell that loads fast over phone data.
    out = canvas.convert('RGB').quantize(colors=64, method=Image.MEDIANCUT)
    out.save(f'{OUT}/{name}', 'PNG', optimize=True)
    print(f'{OUT}/{name}  {size}x{size}  medallion {d}px')


def main() -> None:
    disc = medallion()
    for size in (192, 512):
        write(disc, size, 0.86, f'Icon-{size}.png')
        write(disc, size, 0.60, f'Icon-maskable-{size}.png')
    # Browser tab / bookmark. 32px is the largest size a tab actually uses.
    write(disc, 32, 0.94, '../favicon.png')


if __name__ == '__main__':
    main()
