<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniImage

## Build & gates

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest (needs libUniImage.so)
nimble coverage   # gcov + lcov -> coverage/ (needs lcov; linux/macOS)
nimble docs       # nimib book + API reference -> pages/ (needs nimib)
```

`nimble docs` needs a complete Nim distribution: `--project` builds `dochack`,
which Homebrew's `nim` omits (no `tools/`). choosenim and the CI action ship it.

CI: 3-OS Nim, C ABI, and Python matrices, followed by clean artifact consumers.

## Conventions

- English comments, terse, describe what is done. No "deprecated".
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. C ABI never raises — it maps errors to `UI_EXIF_*` codes.
- A postcondition is cheaper than the body: never re-derives the result by
  calling the function itself.
- C ABI: hand-written `include/UniImage.h` kept in sync with
  `src/UniImage/c_api.nim`; `tests/c` links the header against the lib.
  Built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` — **not**
  `-d:danger`: the ABI parses untrusted image bytes, so Nim's bounds checks
  are kept as defense-in-depth (every entry point also validates handles and
  traps `CatchableError` + `Defect` at the boundary).
- C symbols use the `ui_exif_*` metadata and `ui_image_*` raster namespaces.
  lib `libUniImage`; header `UniImage.h`.
- `core` (image model) is the lowest layer. `compress`, formats, process, and
  metadata point downward; `c_api` may combine them. `process/quantize` adapts
  packed pixels to UniColor and never duplicates its algorithms. Enforced by
  `nimble checkVGraph`.
- `book/index.nim` is nimib: its code blocks are compiled and run at docs build,
  so prose that outlives its API breaks the build. `py/notebooks/quickstart.ipynb`
  plays the same role for Python and renders natively on GitHub.
- End covered sources with a blank line. Nim maps a trailing statement one line
  past EOF. The coverage task limits lcov suppression to that generated
  `range` mapping and empty imported-module `gcov` records; all source and I/O
  errors remain fatal.

## Scope

Public engine repo of the `lituus-lab` family, above `UniColor` in the
dependency DAG. Apache-2.0, DCO. The `exif/` subpackage is
migrated from nim-exif (Apache-2.0); format codecs are reimplemented from specs
— third-party codec implementations are never vendored.
