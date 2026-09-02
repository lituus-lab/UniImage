# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel; this script only
regenerates it after an API change."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PY_ROOT = os.path.join(ROOT, "py")
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", """# UniImage — Python quickstart

`uniimage` is a Cython extension over the UniImage C ABI, shipped as a
self-contained wheel: the native library travels inside the package, so
installing it needs neither Nim nor a compiler.

```
pip install lituus-uniimage
```

CI executes this notebook against the wheel the release actually publishes, so
an output below that stops matching fails the build."""),
    ("md", "## Metadata API"),
    ("code", "import uniimage\n\nuniimage.version(), uniimage.__version__"),
    ("md", "`read_buffer` parses a still/video container's metadata without "
           "decoding pixels. A minimal JPEG (SOI + EOI) carries none:"),
    ("code", "m = uniimage.read_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))\nm.is_valid"),
    ("md", "Strip metadata from a buffer, returning a new bytes object:"),
    ("code", "out = uniimage.strip_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))\nout[:2]"),
    ("md", """## In-place EXIF edit

Open an editable model from a buffer, mutate it, serialize back, then re-read
to confirm the tag round-trips:"""),
    ("code", """jpg = bytes([0xFF, 0xD8, 0xFF, 0xD9])
e = uniimage.edit_buffer(jpg)
e.set_artist("Jane Doe")
e.set_tag("ImageDescription", "quickstart")
edited = e.write()
m = uniimage.read_buffer(edited)
m.get_tag("Artist"), m.get_tag("ImageDescription")"""),
    ("md", """## Raster API

Decode a two-pixel PPM buffer, resize it, encode it as PNG, and decode the
result again. All encoded and pixel buffers are ordinary Python `bytes`."""),
    ("code", """ppm = b"P6\\n2 1\\n255\\n" + bytes([255, 0, 0, 0, 0, 255])
image = uniimage.decode_buffer(ppm)
resized = image.resize(4, 2, uniimage.FILTER_BILINEAR)
png = resized.encode(uniimage.FMT_PNG)
roundtrip = uniimage.decode_buffer(png)
(roundtrip.width, roundtrip.height, roundtrip.channels, png[:4])"""),
    ("md", "Extract a perceptual palette through UniColor's Wu quantizer:"),
    ("code", """palette = image.extract_palette(2, "wu")
len(palette), palette.color_at(0).space_tag"""),
]


def build():
    nb = nbf.v4.new_notebook()
    for kind, src in CELLS:
        if kind == "md":
            nb.cells.append(nbf.v4.new_markdown_cell(src))
        else:
            nb.cells.append(nbf.v4.new_code_cell(src))
    nb.metadata.update({"kernelspec": {"name": "python3", "display_name": "Python 3",
                                       "language": "python"},
                        "language_info": {"name": "python"}})
    # Execute against the repo (in-place extension) so outputs are real.
    client = NotebookClient(nb, resources={"metadata": {"path": PY_ROOT}},
                            allow_errors=False)
    client.execute()
    nbf.write(nb, OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    build()
