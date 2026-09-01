# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "References"

nbText: """
## References

- CIPA, *Exchangeable image file format for digital still cameras: Exif*.
- W3C, *Portable Network Graphics (PNG) Specification*.
- ITU-T T.81, *Digital compression and coding of continuous-tone still
  images* (JPEG).
- Google, *QOI — The Quite OK Image Format*.
"""

nbSave

nbSave
