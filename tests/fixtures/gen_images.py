#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Regenerate the binary fixtures inlined in tests/test_formats.nim.

The Nim test suite inlines a few real-world byte blobs to exercise decoder
code paths that the synthetic helpers cannot reach:

  * PNG gray+alpha (color type 4) 4x2  -- RGBA expansion.
  * JPEG 17x5 4:2:0                   -- partial MCU-grid bounds.
  * JPEG 8x8 grayscale noise          -- full AC zigzag.

These were originally captured with Pillow==12.3.0 (which bundles a fixed
libjpeg-turbo), so the committed bytes are reproducible only with that exact
Pillow version. JPEG is lossy and libjpeg-version dependent: regenerating with
a different Pillow/libjpeg pair yields a different byte stream (though the
decoder still validates the same structural properties the tests assert).

Run with the matching toolchain::

    pip install "Pillow==12.3.0"
    python tests/fixtures/gen_images.py            # writes *.png/*.jpg
    python tests/fixtures/gen_images.py --dump-nim  # also prints Nim @[byte ...]

The PNG fixture is lossless and byte-exact. The JPEG blobs are checked in as
captured; use --dump-nim to refresh the inlined literals after a deliberate
toolchain bump, then eyeball that the tests still pass.
"""
import argparse
import io
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    raise SystemExit("Pillow is required: pip install 'Pillow==12.3.0'")

OUT = Path(__file__).resolve().parent

# --- PNG gray+alpha (color type 4), 4x2 -------------------------------------
# Each pixel is (gray, alpha). The decoder replicates gray to RGB and places
# alpha in A. Matches the byte-exact assertion in test_formats.nim.
PNG_GA_PIXELS = [
    (10, 200), (20, 210), (30, 220), (40, 230),
    (50, 0),   (60, 255), (70, 128), (80, 40),
]


def make_png_gray_alpha() -> bytes:
    img = Image.new("LA", (4, 2))
    img.putdata(PNG_GA_PIXELS)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# --- JPEG vectors ----------------------------------------------------------
# 17x5 RGB 4:2:0: a small gradient with a non-multiple-of-16 width so the MCU
# grid (2x1 MCUs of 16x16) has a partial right column. The committed blob is the
# Pillow output; the exact source pixels were chosen to produce non-flat luma.
def make_jpeg_420() -> bytes:
    img = Image.new("RGB", (17, 5))
    for y in range(5):
        for x in range(17):
            img.putpixel((x, y), (x * 15, y * 51, (x + y) * 10))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=95, subsampling="4:2:0")
    return buf.getvalue()


# 8x8 grayscale noise: high-frequency AC so decodeBlock walks the full zigzag.
def make_jpeg_gray_noise() -> bytes:
    # Deterministic pseudo-noise so the blob is reproducible from this script.
    px = bytes(((x * 73 + y * 41 + (x ^ y) * 17) & 0xFF) for y in range(8) for x in range(8))
    img = Image.frombytes("L", (8, 8), px)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=95)
    return buf.getvalue()


def to_nim_literal(name: str, blob: bytes) -> str:
    parts = [f"0x{b:02X}" for b in blob]
    lines = []
    for i in range(0, len(parts), 12):
        lines.append("    " + ", ".join(parts[i:i + 12]))
    return f"# {name} ({len(blob)} bytes)\n  @[byte\n" + "\n".join(lines) + "\n  ]"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dump-nim", action="store_true",
                    help="also print Nim @[byte ...] literals for pasting into tests")
    args = ap.parse_args()

    png_ga = make_png_gray_alpha()
    jpg_420 = make_jpeg_420()
    jpg_noise = make_jpeg_gray_noise()

    (OUT / "png_gray_alpha_4x2.png").write_bytes(png_ga)
    (OUT / "jpeg_420_17x5.jpg").write_bytes(jpg_420)
    (OUT / "jpeg_gray_noise_8x8.jpg").write_bytes(jpg_noise)
    print(f"wrote {OUT / 'png_gray_alpha_4x2.png'} ({len(png_ga)} bytes)")
    print(f"wrote {OUT / 'jpeg_420_17x5.jpg'} ({len(jpg_420)} bytes)")
    print(f"wrote {OUT / 'jpeg_gray_noise_8x8.jpg'} ({len(jpg_noise)} bytes)")

    if args.dump_nim:
        print("\n# ---- Nim literals (Pillow 12.3.0) ----")
        print(to_nim_literal("PNG gray+alpha 4x2", png_ga))
        print(to_nim_literal("JPEG 4:2:0 17x5", jpg_420))
        print(to_nim_literal("JPEG grayscale noise 8x8", jpg_noise))


if __name__ == "__main__":
    main()
