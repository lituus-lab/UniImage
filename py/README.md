<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# uniimage

Raster decoding, encoding, processing, and image metadata for Python, backed
by the native [UniImage](https://github.com/lituus-lab/UniImage) engine written
in Nim.

`uniimage` decodes images into owned 8-bit pixel buffers, resizes, crops,
rotates, applies EXIF orientation, composites straight-alpha layers, encodes
supported output formats, and
extracts perceptual palettes. Its metadata surface reads, edits, and strips
EXIF data without first decoding the pixels.

## Install

```bash
pip install uniimage
```

Prebuilt wheels include the native UniImage library for Linux, macOS, and
Windows on CPython 3.9–3.14. Installing a wheel needs neither Nim nor a C
compiler.

## Quick start

```python
from pathlib import Path

import uniimage

image = uniimage.decode_buffer(Path("input.png").read_bytes())
resized = image.resize(800, 600, uniimage.FILTER_BILINEAR)
Path("output.jpg").write_bytes(
    resized.encode(uniimage.FMT_JPEG, quality=90)
)

metadata = uniimage.read_buffer(Path("photo.jpg").read_bytes())
print(metadata.orientation)
print(metadata.gps)
print(metadata.tags)

clean = uniimage.strip_buffer(Path("photo.jpg").read_bytes())
Path("photo.clean.jpg").write_bytes(clean)
```

The API accepts and returns `bytes`; file I/O stays under the caller's control.
`Image.pixels` also returns a copy, so its lifetime is independent of the
native buffer.

## What's included

| Category | Python API |
|---|---|
| Decode and construct | `decode_buffer`, `image_from_pixels`, `thumbnail` |
| Image inspection | `Image.width`, `height`, `channels`, `colorspace`, `pixels` |
| Processing | `Image.resize`, `crop`, `rotate`, `orient`, `composite_over` |
| Encoding | `Image.encode` |
| Palette extraction | `Image.extract_palette`, `Palette`, `Color` |
| Metadata | `read_buffer`, `edit_buffer`, `strip_buffer` |
| ABI information | `version`, `abi_version`, `image_abi_version` |

Decoding supports PNG, JPEG, BMP, QOI, PNM/PAM, TGA, PCX, GIF, lossless WebP,
and baseline TIFF. Encoding supports PNG, JPEG, BMP, QOI, PNM/PAM, and
TGA. Pass `FMT_TGA` when decoding TGA because the format has no magic
signature. Unsupported input and invalid operations raise `ValueError`.

Palette extraction exposes `wu`, `kmeans`, `kmeansPP`, `medianCut`, `octree`,
and `neuquant`. `Image.orient` accepts the eight EXIF Orientation values.
`Image.composite_over` mutates an RGBA destination; its source may be Gray, RGB,
or straight-alpha RGBA, placement clips, and opacity is an integer from 0 to
255. `Image.pixels` remains a caller-owned `bytes` copy after the mutation.

For an executable tour of both raster and metadata operations, see the
[Python quickstart notebook](https://github.com/lituus-lab/UniImage/blob/main/py/notebooks/quickstart.ipynb).

## Links

- Source, Nim API, C ABI, and design records: <https://github.com/lituus-lab/UniImage>
- Documentation: <https://lituus-lab.github.io/UniImage/>
- Issues: <https://github.com/lituus-lab/UniImage/issues>
- License: Apache-2.0

## Development

Building from source requires Nim, Nimble, a C compiler, Cython, and Python
development headers.

```bash
nimble install -y
nimble pyLib
cd py
python3 setup.py build_ext --inplace
python3 -m pytest -q
```

On Windows, run the commands from a Developer Command Prompt and use `python`
if `python3` is not available. `nimble pyLib` builds the MSVC-compatible static
library used by the extension.

An installation from the source distribution follows the same native build
path and therefore also requires Nim and Nimble on `PATH`.
