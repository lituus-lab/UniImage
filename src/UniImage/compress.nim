# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Pure-Nim compression: DEFLATE (RFC 1951) inflate + compress (fixed-Huffman
## LZ77) and a zlib (RFC 1950) container reader + writer. PNG decodes its IDAT
## stream through `zlibInflate` and encodes it through `zlibDeflate`. No system
## zlib dependency is required.
import UniImage/core
import ./compress/deflate
import ./compress/zlib

export core
export deflate
export zlib
