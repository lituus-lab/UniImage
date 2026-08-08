<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# uniimage — Python binding

```bash
nimble pyLib                                    # native lib for this platform
(cd py && python3 setup.py build_ext --inplace) # build the Cython extension
(cd py && python3 -m pytest -q)                 # test
```

`nimble pyLib` builds the shared lib on Linux/macOS and the MSVC static lib on
Windows, so the same commands work everywhere. The subshells keep your shell's
cwd unchanged.

```python
import uniimage
uniimage.version()       # "1.0.0"
m = uniimage.read_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
m.is_valid               # False (no metadata in a bare JPEG)

img = uniimage.decode_buffer(b"P6\n1 1\n255\n\xff\x00\x00")
palette = img.extract_palette(1, "wu")
palette.color_at(0).space_tag  # COLOR_SPACE_OKLAB
```
