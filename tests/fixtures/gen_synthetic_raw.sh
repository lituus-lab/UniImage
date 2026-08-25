#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Regenerates synthetic-raw.tiff, the TIFF-container fixture the EXIF write
# tests use.
#
# A vendor RAW -- DNG, NEF, CR2, ARW, RW2, ORF -- is a TIFF container carrying
# the sensor data, so a TIFF with a populated EXIF IFD exercises the same write
# path without shipping anyone's photograph. The pixels are a generated
# gradient, so the fixture is this repository's to license.
#
# Needs ImageMagick and exiftool. Byte-for-byte reproducibility is not claimed:
# both write their own version strings.
set -eu
out="$(dirname "$0")/synthetic-raw.tiff"
magick -size 16x16 -depth 8 gradient:navy-white "$out"
exiftool -overwrite_original \
  -DateTimeOriginal="2019:03:14 09:26:53" \
  -Make="lituus-lab" -Model="Synthetic RAW Camera" \
  -EXIF:LensModel="Synthetic 50mm" -Artist="lituus-lab" \
  -GPSLatitude=45.9 -GPSLatitudeRef=N \
  -GPSLongitude=6.6 -GPSLongitudeRef=E \
  "$out"
