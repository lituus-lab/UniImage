<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: UniImage engine and foreign façades

- Status: Accepted
- Date: 2026-07-15
- Scope: UniImage

## Decision

- **Engine** (pure Nim): the library + a thin C ABI (`src/UniImage/c_api.nim`),
  built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` →
  `libUniImage.a` / `libUniImage.so`. No UI in the engine.
- **Shell** (native UI, separate private repo): links the C ABI, owns the UI.
- **C header** (`include/UniImage.h`): hand-written, kept in sync with `c_api.nim`.
  `tests/c` links the header against the lib — a renamed/retyped symbol fails
  to link, so the C test is the ABI drift detector. (`--header:X.h` auto-gen is
  not used.)
- `--mm:arc`: deterministic memory model for foreign callers (no cycle
  collector). `--noMain` disables the application entry point; C callers still
  invoke `ui_exif_init()` exactly once before every other ABI function.
- **Python binding**: Cython over the shared library, with the native library
  bundled beside the extension and resolved through its platform loader path.

## Binding boundary

The Nim API is authoritative. It owns image decoding and encoding, metadata,
compression, pixel transforms and color processing. C and Python contain only
type conversion, ownership and error translation; they do not reimplement an
image operation.

The stable foreign representation is an opaque 8-bit decoded image handle.
Generic `Image[P]` construction and `Image[float32]` HDR buffers remain Nim-only
because they have no single C layout. Individual codec entry points remain
Nim-only; C and Python reach them through the format-dispatching decode and
encode functions. Low-level endian, IFD, container and Deflate helpers are
implementation details rather than parallel foreign APIs.

Python wraps the buffer-based C surface. Python callers use their own file I/O,
avoiding a second set of path and filename-encoding rules in the extension.
