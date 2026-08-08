<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0001: UniImage dependency direction

- Status: Accepted
- Date: 2026-07-15
- Scope: UniImage

## Decision

UniImage is a layer-3 engine. It may depend on layer-0 UniColor and external
build infrastructure, while UniPercept, UniVector, UniBarCode, UniGlyph, and
UniMedia depend on UniImage. `nimble checkVGraph` rejects an import that points
back toward a consumer.

## Invariants

1. `core` imports no other UniImage domain layer.
2. `compress` may import `core`; `formats` may import `core` and `compress`.
3. `process` may import `core`; metadata modules may import `compress`, but do
   not import image codecs.
4. The umbrella module and C ABI may combine the lower layers.
5. UniImage never imports a consuming engine or an application.
6. NimContracts and UniColor stay external and track their maintained `main`
   branches during coordinated pre-release development.

EXIF remains a subpackage because its public consumers also use UniImage's
raster domain; importing `UniImage/exif` does not load codec modules.
