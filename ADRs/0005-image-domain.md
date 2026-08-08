<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0005: UniImage raster domain

- Status: Accepted
- Date: 2026-07-27
- Updated: 2026-08-08
- Scope: UniImage

## Context

UniImage is the raster engine for the lituus-lab Uni* family. It owns encoded
image formats, decoded pixel buffers, metadata tied to image containers, and
pixel transforms. It must not duplicate the color science owned by UniColor.

## Decision

The public Nim surface consists of:

- `core`: generic `Image[P]`, colorspace tags, and image errors;
- `compress`: pure-Nim RFC 1950 zlib and RFC 1951 Deflate;
- `formats`: raster decoding and encoding implemented in Nim;
- `process`: resizing, cropping, orthogonal transforms, EXIF orientation, and
  palette extraction;
- `exif`: EXIF, XMP, IPTC-IIM, MakerNote, thumbnail, and container metadata;
- the `uniimg` CLI and the C/Python foreign façades.

Palette extraction adapts Gray/RGB/RGBA `Image[uint8]` buffers to typed sRGB
pixels and calls UniColor's quantizer registry. Wu, k-means, k-means++, median
cut, octree, and NeuQuant remain implemented exactly once, in UniColor.

The metadata zlib compatibility adapter uses UniImage's pure-Nim compressor.
The engine therefore has no system-zlib FFI or `-lz` consumer requirement.
NimContracts remains external and follows the maintained `main` branch, as
does UniColor during coordinated Uni* release development.

The C ABI is built with `-d:release`, not `-d:danger`, because it parses
untrusted bytes and keeps Nim's bounds and overflow checks as defense in depth.

## Consequences

- UniColor never imports a raster codec and UniImage never reimplements its
  color algorithms.
- Higher-level engines can depend on one decoded image type and one codec
  dispatcher.
- Metadata consumers can migrate from nim-exif while retaining a standalone
  `UniImage/exif` import.
- C consumers of the static library do not need Nim or a system zlib.
