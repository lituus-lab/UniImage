# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniImage compatibility adapter over the UniCompress zlib format.

import UniImage/core
import UniCompress as uc

proc mapError(error: uc.UniCompressException): UniImageException =
  let code = case error.code
    of uc.ucUnsupported: uiUnsupported
    of uc.ucTruncated: uiTruncated
    of uc.ucInvalidData, uc.ucResourceLimit: uiInvalidArg
  UniImageException(code: code, msg: error.msg)

proc zlibInflate*(data: openArray[byte];
    maxOutput: int64 = 1'i64 shl 32): seq[byte] =
  ## Decode and verify one RFC 1950 zlib stream under an output bound.
  try:
    uc.zlibInflate(data, maxOutput)
  except uc.UniCompressException as error:
    raise mapError(error)

proc zlibDeflate*(data: openArray[byte]): seq[byte] =
  ## Encode `data` as a deterministic RFC 1950 zlib stream.
  uc.zlibDeflate(data)
