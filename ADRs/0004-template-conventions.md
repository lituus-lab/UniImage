<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: UniImage conventions

- Status: Accepted
- Date: 2026-07-15
- Scope: UniImage

## Layout

```text
UniImage.nimble          package + tasks
config.nims                 arch-conditional build flags
src/UniImage.nim         umbrella
src/UniImage/core.nim    image model (NimContracts)
src/UniImage/exif.nim    metadata facade
src/UniImage/exif/       metadata submodules (migrated from nim-exif)
src/UniImage/c_api.nim   C ABI
include/UniImage.h       hand-written C header
bin/uniimg.nim           CLI (inspect / strip)
tests/ tests/c/             Nim + C ABI tests
examples/                   Nim + C demos
py/                         Cython binding + pytest
book/                       nimib book (drift detector)
ADRs/                       0001–0005
.github/workflows/ci.yml    3-OS Nim + C ABI + Python
LICENSE NOTICE CONTRIBUTING.md SECURITY.md .gitignore README.md AGENTS.md CLAUDE.md
```

## Naming

- Nim package/module: `UniFoo` (PascalCase).
- C library: `libUniFoo`. C header: `UniFoo.h`.
- C symbol prefix: the lib's short token (`ui_` here; `ua_`, `um_`, `ulin_`…).

## Conventions

- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. The C ABI never raises — it maps errors to `UI_EXIF_*`
  and `UI_IMAGE_*` codes.
- A postcondition is cheaper than the body; it never re-derives the result.
- English comments, terse, describe what is done. No "deprecated".
- C ABI builds `-d:release` (not `-d:danger`): parses untrusted image bytes.
- `core` is the lowest layer; `exif` is metadata-only but may import `core`
  when the metadata model needs the image buffer; `c_api` may import both.
  Enforced by `nimble checkVGraph`. Format codecs sit above `core`.

## CI gates

- `nimble testCi` + `testCiRelease` on ubuntu/macOS/Windows.
- `nimble ctest` on Linux, macOS and Windows.
- `nimble pyTest` on Linux, macOS and Windows.
- Built C and wheel artifacts are consumed on clean runners without Nim.
