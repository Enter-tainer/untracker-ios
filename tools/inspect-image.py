#!/usr/bin/env python3
"""Print objective statistics about a PNG so image output can be checked without eyes.

Used for QA of the generated app icon and of simulator/device screenshots (to
distinguish "app rendered" from "blank / crashed / launch-screen-only").

    python tools/inspect-image.py image.png [image2.png ...]
"""

import sys

from PIL import Image


def quantize(pixel, bits=4):
    shift = 8 - bits
    return tuple(channel >> shift for channel in pixel[:3])


def analyse(path):
    with Image.open(path) as image:
        image = image.convert("RGB")
        width, height = image.size
        pixels = list(image.getdata())

    total = len(pixels)
    counts = {}
    for pixel in pixels:
        key = quantize(pixel)
        counts[key] = counts.get(key, 0) + 1

    top = sorted(counts.items(), key=lambda item: -item[1])[:5]
    mean = tuple(sum(p[i] for p in pixels) // total for i in range(3))

    def sample(x_fraction, y_fraction):
        x = min(width - 1, int(width * x_fraction))
        y = min(height - 1, int(height * y_fraction))
        return pixels[y * width + x]

    white = sum(1 for p in pixels if p[0] > 240 and p[1] > 240 and p[2] > 240)
    dark = sum(1 for p in pixels if p[0] < 40 and p[1] < 40 and p[2] < 40)

    print(f"== {path}")
    print(f"   size            : {width}x{height}")
    print(f"   quantised colours: {len(counts)}")
    print(f"   mean RGB        : {mean}")
    print(f"   white px        : {white} ({100 * white / total:.1f}%)")
    print(f"   near-black px   : {dark} ({100 * dark / total:.1f}%)")
    print("   top colours     :")
    for colour, count in top:
        print(f"     {colour}  {100 * count / total:5.1f}%")
    print("   samples         :")
    for name, (fx, fy) in {
        "top-left": (0.03, 0.03),
        "top-right": (0.97, 0.03),
        "centre": (0.5, 0.5),
        "bottom-left": (0.03, 0.97),
        "bottom-right": (0.97, 0.97),
    }.items():
        print(f"     {name:12s}: {sample(fx, fy)}")
    print()


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for path in sys.argv[1:]:
        try:
            analyse(path)
        except Exception as error:  # noqa: BLE001 - CLI tool
            print(f"== {path}\n   ERROR: {error}\n")


if __name__ == "__main__":
    main()
