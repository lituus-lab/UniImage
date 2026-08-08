# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import UniImage

echo "UniImage " & UniImageVersion
# A minimal JPEG: SOI + EOI, no metadata.
let m = readMetadataFromBytes([byte 0xFF, 0xD8, 0xFF, 0xD9])
echo "isValid=", m.isValid
let stripped = stripMetadataBytes([byte 0xFF, 0xD8, 0xFF, 0xD9])
echo "stripped bytes=", stripped.len
