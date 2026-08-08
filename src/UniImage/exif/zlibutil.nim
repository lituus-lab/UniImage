# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Compatibility adapter for compressed PNG metadata text.
##
## The metadata parser historically treats malformed or empty compressed text
## as absent, so this adapter keeps that behavior while using UniImage's
## pure-Nim RFC 1950/1951 implementation.
import UniImage/core
import UniImage/compress/zlib as pureZlib

const MaxTextOutput = 16 * 1024 * 1024

proc zlibInflate*(src: openArray[byte]): seq[byte] =
  ## Inflate a zlib stream, returning an empty sequence when it is invalid.
  try:
    pureZlib.zlibInflate(src, MaxTextOutput)
  except UniImageException:
    @[]

proc zlibDeflate*(src: openArray[byte]; level = 6): seq[byte] =
  ## Deflate to a zlib stream. `level` is retained for source compatibility;
  ## UniImage's deterministic fixed-Huffman encoder has no compression levels.
  discard level
  pureZlib.zlibDeflate(src)
