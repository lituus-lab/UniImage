# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "C and Python"

nbText: """
## The C ABI

The metadata surface is exposed as `ui_exif_*` (migrated from nim-exif's
ABI v1). The header is hand-written and kept in sync with
`src/UniImage/c_api.nim`; `tests/c` links one against the other on every CI
run, so a drift is caught rather than shipped.

Palette extraction uses an immutable `ui_palette` handle whose tagged colors
retain UniColor's working-space identity. The same handle is wrapped by the
Python `Palette` class.

Raster compositing is additive ABI-v1 surface. It mutates only the owned
destination handle and accepts the same 0–255 opacity as the Nim API:

```c
int ui_image_composite_over(ui_image destination, ui_image source,
                            int x, int y, int opacity);
```

```c
void        ui_exif_init(void);
int         ui_exif_read_buffer(const unsigned char* data, size_t length,
                                ui_exif_meta* out_handle);
const char* ui_exif_to_json(ui_exif_meta h);
```

The C ABI **never raises**. Every entry point validates its arguments and
traps both `CatchableError` and `Defect`, mapping them to a `ui_exif_status`
or `ui_image_status` code. Built
`--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` —
`-d:release` (not `-d:danger`) keeps Nim's bounds checks as a backstop while
parsing untrusted image bytes.

## The Python surface

A Cython extension over the C ABI, shipped as a self-contained wheel: the
library travels inside the package, so installing it needs neither Nim nor a
compiler.

```python
import uniimage

m = uniimage.read_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
m.is_valid          # False

destination = uniimage.image_from_pixels(
    24, 16, bytes(24 * 16 * 4), uniimage.CS_RGBA
)
source = uniimage.image_from_pixels(
    4, 4, bytes(4 * 4 * 4), uniimage.CS_RGBA
)
destination.composite_over(source, x=12, y=8, opacity=192)
```
"""

nbSave
