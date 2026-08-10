<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniImage

A raster image engine written in Nim, with a C ABI and Python binding.
UniImage provides an image model, pure-Nim codecs and Deflate, pixel
processing, EXIF/XMP/IPTC metadata handling, and the `uniimg` command-line
tool.

## What's inside

- `UniImage/core`: typed pixel buffers, color-space tags, and error values.
- `UniImage/formats`: PNG, JPEG, BMP, QOI, PNM/PAM, TGA, PCX, HDR, GIF,
  lossless WebP, and baseline TIFF decoding; PNG, JPEG, BMP, QOI, PNM/PAM,
  and TGA encoding.
- `UniImage/compress`: pure-Nim Deflate and zlib streams.
- `UniImage/process`: resize, crop, rotation, flips, EXIF orientation, and
  palette extraction through UniColor's Wu, k-means, k-means++, median-cut,
  octree, and NeuQuant implementations.
- `UniImage/exif`: EXIF, XMP, IPTC-IIM, MakerNote, thumbnail, and ISOBMFF
  metadata parsing and editing.

## Codec support

| Format | Decode | Encode | Boundary |
|---|---:|---:|---|
| PNG | yes | yes | non-interlaced; 8-bit Gray/RGB/RGBA output |
| JPEG | baseline | yes | 8-bit Gray and YCbCr decode |
| BMP | yes | yes | uncompressed; 1/4/8/24/32-bit decode |
| QOI | yes | yes | RGB and RGBA |
| PNM/PAM | yes | yes | PBM, PGM, PPM, PAM |
| TGA | yes | yes | call `decodeTga`/pass `FMT_TGA`; no magic signature |
| PCX | yes | no | indexed and true-color |
| HDR | yes | no | Radiance RGBE |
| GIF | yes | no | first frame |
| WebP | lossless | no | VP8L; see [Codec boundaries](#codec-boundaries) |
| TIFF | baseline | no | chunky layouts; see [Codec boundaries](#codec-boundaries) |

## Layout

```
src/UniImage.nim          umbrella module
src/UniImage/core.nim     image model: error codes, color spaces, Image[P]
src/UniImage/exif.nim     EXIF/XMP/IPTC metadata facade
src/UniImage/exif/        metadata submodules (migrated from nim-exif)
src/UniImage/c_api.nim    C ABI (ui_exif_* and ui_image_*)
include/UniImage.h        hand-written C header
bin/uniimg.nim            CLI: inspect, edit, strip, convert, and transform
tests/                    Nim and C ABI tests
examples/                 Nim and C demos
py/                       Cython binding and pytest suite
ADRs/                     architecture decisions
.github/workflows/ci.yml     3-OS Nim matrix + C ABI + Python
```

## Build

```bash
nimble install -y
nimble test           # Nim, debug (contracts active)
nimble testRelease    # Nim, release (contracts compiled away)
nimble testAll        # debug + release + C ABI
nimble ctest          # C ABI: static lib + tests/c
nimble cexample       # C demo
nimble example        # Nim demo
nimble pyTest         # Cython + pytest
nimble coverage       # gcov + lcov -> coverage/
nimble book           # nimib book -> book/index.html
nimble docs           # book + API reference -> pages/
nimble checkVGraph     # enforce downward-only imports
```

The C ABI builds `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`
— **not** `-d:danger`: the ABI parses untrusted image bytes, so Nim's bounds
checks are kept as defense-in-depth.

## C ABI and Python binding

The hand-written [`UniImage.h`](include/UniImage.h) exposes two stable v1
namespaces: `ui_exif_*` for metadata and `ui_image_*` for decoded rasters.
Every entry point validates handles and maps failures to status codes; no Nim
exception crosses the ABI boundary.

The [`uniimage`](py/README.md) Python package wraps the same ABI. Release
wheels bundle the native library for Linux, macOS, and Windows on CPython
3.9–3.14, so installing a wheel needs neither Nim nor a C compiler. The
[Python quickstart notebook](py/notebooks/quickstart.ipynb) is executed in CI
against the built wheel.

## Command line

Build the CLI with `nimble uniimg`, then run `bin/uniimg` (or
`bin/uniimg.exe` on Windows):

```text
uniimg show photo.jpg --json
uniimg audit photo.jpg
uniimg strip photo.jpg photo.clean.jpg
uniimg convert input.png output.jpg --quality=90
uniimg resize input.png output.png 1280x720
uniimg crop input.png output.png 10,20,640x480
uniimg rotate input.png output.png 90
```

`xmp`, `thumb`, and `set` cover XMP inspection, embedded-thumbnail extraction,
and EXIF/IPTC editing. Run `uniimg` without arguments for the complete usage.

## Codec boundaries

WebP decoding covers lossless VP8L and unfiltered raw or lossless-compressed
`ALPH` payloads. Lossy VP8, animation, filtered alpha and preprocessed alpha
return `uiUnsupported`; malformed RIFF/chunk boundaries are rejected. TIFF
decoding covers the baseline chunky formats listed by the API documentation
and bounds the total decoded pixel count before allocating.

## Preserving XMP edits

`mergeXmp` applies an explicit `XmpPatch` to an existing packet. Unset fields
remain untouched, empty values remove only the selected property, and unrelated
attributes, elements, list structures, comments and namespace declarations are
preserved. This is the safe foundation for applications that must edit standard
fields without rebuilding a lossy subset of third-party metadata.

## Normalizing display orientation

`applyExifOrientation` applies all eight EXIF orientations to decoded pixels,
including the two diagonal reflections. It returns an independent buffer and
rejects values outside `1..8`; callers should use orientation `1` when metadata
is absent. This keeps thumbnail and export pipelines from carrying container
orientation semantics into their display layer.

## Extracting a palette

`extractPalette` accepts an 8-bit Gray, RGB, or RGBA `Image` and delegates the
perceptual work to UniColor. Wu is the deterministic default; `kmeans`,
`kmeansPP`, `medianCut`, `octree`, and `neuquant` select the other historical
algorithms. UniImage contains only the packed-pixel adapter, so the algorithms
have one implementation and one registry.

```nim
let result = image.extractPalette(8, "wu")
if result.isOk:
  echo result.get.len
```

The C ABI exposes the result as an immutable `ui_palette` handle containing
tagged `ui_color` values. Python mirrors it with `Image.extract_palette`,
`Palette`, and `Color`; all six quantizer options remain explicit.

## CI

Nim, C ABI, and Python jobs run on Ubuntu, macOS, and Windows.
`consume-cabi` and `consume-wheel` rebuild against the produced artifacts on a
machine without Nim, so what ships is what was tested. `coverage` and `docs`
run on Ubuntu.

`dco` blocks PRs missing a `Signed-off-by` trailer; `commitizen` blocks PRs whose
commits or title are not [Conventional Commits](https://www.conventionalcommits.org/)
(`CONTRIBUTING.md`).

The same gates run locally with pre-commit: `pip install pre-commit && pre-commit install`
(`CONTRIBUTING.md`).

The `docs` job always builds the executable book and API reference. Following
the other Uni* repositories, the separate Pages job publishes them only from
`main` when the repository is public.

## The Uni* family

UniImage is a layer-3 engine. It depends downward on UniColor and is the raster
foundation for higher-level perception, vector, barcode, glyph, and media
engines. The family principles are documented in
[`lituus-lab/.github`](https://github.com/lituus-lab/.github).

## Provenance & development

The metadata package originated in the hand-written `nim-exif` library and was
integrated under Apache-2.0. The codecs are implementations of public format
specifications; no third-party codec implementation is vendored. The design
predates this repository's short, linear publication history. An agent-assisted
rewrite and verification pass organized the pre-existing work for release;
the human maintainer remains responsible for every shipped line. `NOTICE`
records the included provenance.

## Benchmarks

UniImage does not currently ship a benchmark harness. Codec work is validated
for correctness and bounded resource use; this repository makes no performance
claim without a reproducible measurement.

## AI-assisted contributions

Assistance from AI/LLM tools is welcome on the same terms as any other
contribution.

- **Accountability.** The human contributor is the author and remains fully
  responsible for the change. The DCO sign-off (`Signed-off-by`) is the mechanism:
  by signing you certify the content is yours or properly licensed — this covers
  AI-assisted work, provided you can stand behind it.
- **No third-party contamination.** Ensure AI output introduces no code from a
  third party without a compatible license and attribution. If an LLM reproduced
  protected material, do not submit it.
- **Correctness is yours.** The gates (tests, `nimble lint`, conventional commits,
  pre-commit) catch a lot, but you own the result — review and verify what you
  commit.
- **Atomic commits.** Each commit is one logical change. A PR may stack
  several atomic commits (one per element, say) — one monolithic big-bang
  commit is not.
- **Disclosure.** State in the PR whether AI assistance was used (see the PR
  template). It is not a hard requirement — the DCO remains the gate.

## License

Apache-2.0 (`LICENSE`). DCO sign-off on every commit (`CONTRIBUTING.md`).
