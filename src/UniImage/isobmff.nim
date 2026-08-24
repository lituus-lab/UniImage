# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The ISO base media box layer.
##
## The walk itself lives in `UniContainer`, which owns container framing for
## the family: MP4, MOV, HEIF, AVIF and an ALAC `.m4a` are the same structure,
## so one box reader serves an image library, a video library and an audio one
## rather than each writing its own.
##
## Re-exported here so the modules that read HEIF and the Exif item inside an
## MP4 name the box layer where they always have.

import UniContainer/isobmff
export isobmff

