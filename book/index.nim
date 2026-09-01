# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "UniImage"

nbText: """
# UniImage

Pure-Nim raster image engine with C and Python façades. Apache-2.0, DCO.

UniImage combines a generic **core image model** (`Image[P]`, color spaces,
error codes), raster codecs, pure-Nim Deflate, pixel processing, and an
**EXIF/XMP/IPTC metadata** package derived from nim-exif.

WebP support is deliberately lossless-only: VP8L and unfiltered raw or
lossless-compressed alpha are decoded exactly. Lossy, animated, filtered-alpha
and preprocessed-alpha inputs are rejected explicitly. TIFF similarly exposes
only its documented baseline chunky subset rather than approximating unsupported
layouts.

This page is a nimib book: every Nim block below is compiled and run when
the book is built. A change that breaks the API breaks the docs build, so
the two cannot drift apart.
"""

nbSave
