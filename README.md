<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniImage

Pure-Nim raster image engine with C and Python façades. Apache-2.0, DCO.
UniImage sits above `UniColor` in the dependency DAG and is consumed by
`UniPercept`, `UniVector`, `UniBarCode`, `UniGlyph`, and `UniMedia`.

The engine provides an image model, EXIF/XMP/IPTC metadata, pure-Nim raster
codecs, Deflate, pixel processing, the `uniimg` CLI, the stable `ui_` C ABI,
and a Python binding over that ABI.

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
```

The C ABI builds `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`
— **not** `-d:danger`: the ABI parses untrusted image bytes, so Nim's bounds
checks are kept as defense-in-depth.

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
`Palette`, and `Color`; all five quantizer options remain explicit.

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

`docs` publishes the generated book and API reference to GitHub Pages.

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
