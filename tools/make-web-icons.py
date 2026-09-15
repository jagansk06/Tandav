#!/usr/bin/env python3
"""Regenerate the PWA icons in mobile/web/icons/ and the iOS AppIcon set.

Run from the repo root:  python tools/make-web-icons.py   (needs Pillow)

The master artwork is the committed `mobile/web/icons/Icon-512.png` — the
studio lock-up (medallion + "TANDAV" wordmark) already sized and positioned by a
previous run. Every other icon is a resize of it, so re-running this script is
byte-for-byte stable.

Two flavours are written, and the difference matters:

* `Icon-<n>.png`       — the artwork fills most of the square. Used as-is by
                          iOS (which rounds the corners itself) and by browser
                          tabs.
* `Icon-maskable-<n>.png` — Android may crop this to a circle, a squircle or a
                          rounded square of its choosing, and only the middle
                          80% is guaranteed to survive. So the medallion is
                          drawn much smaller, well inside that safe zone. It
                          looks over-padded on its own; that is correct. The
                          maskable master is likewise taken from the committed
                          files so the layout stays as designed.

WHY TRUECOLOR, NOT PALETTE (this bit matters):

Earlier runs wrote 64-colour palette PNGs to keep the 512px file ~67 KB. That
turned out to be a bug: Safari on iOS refuses 8-bit `colormap` PNGs for the
home-screen icon, and renders them as a grey/black blob. iOS also requires the
`apple-touch-icon` (which it reads from <link> in index.html, never from
manifest.json) to be a 180x180 PNG with NO alpha channel. So every icon here is
written as truecolor (RGBA), and `apple-touch-icon.png` as opaque RGB.
"""

from PIL import Image

WEB = 'mobile/web/icons'
IOS = 'mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset'

MASTER = f'{WEB}/Icon-512.png'          # committed brand art (RGBA)
MASKABLE = f'{WEB}/Icon-maskable-512.png'  # committed maskable layout


def save(path: str, im: Image.Image, rgb: bool = False) -> None:
    im = im.convert('RGB' if rgb else 'RGBA')
    im.save(path, 'PNG', optimize=True)
    print(f'{path}  {im.size[0]}x{im.size[1]}  {"RGB" if rgb else "RGBA"}')


def main() -> None:
    art = Image.open(MASTER).convert('RGBA')
    mask = Image.open(MASKABLE).convert('RGBA')

    for src, size, name in [
        (art, 192, 'Icon-192.png'),
        (art, 512, 'Icon-512.png'),
        (mask, 192, 'Icon-maskable-192.png'),
        (mask, 512, 'Icon-maskable-512.png'),
        (art, 32, 'favicon.png'),
        (art, 180, 'apple-touch-icon.png'),
        (art, 167, 'apple-touch-icon-167x167.png'),
        (art, 152, 'apple-touch-icon-152x152.png'),
        (art, 120, 'apple-touch-icon-120x120.png'),
    ]:
        # Apple's icon must be opaque (no alpha) to survive the home screen;
        # the others may keep an alpha channel as long as it is truecolor.
        # 180x180 is the modern iPhone's size, 167 the iPad Pro's, 152 the
        # iPad's and 120 older iPhones — every one written out so iOS on any
        # device can pick its springboard size without resampling at install
        # time (see the <link> block in mobile/web/index.html).
        save(f'{WEB}/{name if name != "favicon.png" else "../favicon.png"}',
             src.resize((size, size), Image.LANCZOS), rgb=('apple-touch' in name))

    # iOS AppIcon set: every size opaque RGB, no alpha, no palette.
    sizes = {
        'Icon-App-20x20@1x.png': 20,
        'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60,
        'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58,
        'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40,
        'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120,
        'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180,
        'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152,
        'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }
    for name, size in sizes.items():
        save(f'{IOS}/{name}', art.resize((size, size), Image.LANCZOS), rgb=True)


if __name__ == '__main__':
    main()