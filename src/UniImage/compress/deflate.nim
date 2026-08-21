# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniImage compatibility adapter over UniCompress Deflate.

import UniImage/core
import UniCompress as uc
import contracts

const MaxInflateOutput* = uc.MaxInflateOutput

proc mapError(error: uc.UniCompressException): UniImageException =
  let code = case error.code
    of uc.ucUnsupported: uiUnsupported
    of uc.ucTruncated: uiTruncated
    of uc.ucInvalidData, uc.ucResourceLimit: uiInvalidArg
  UniImageException(code: code, msg: error.msg)

proc inflateWithConsumed*(data: openArray[byte]; start = 0;
    maxOutput: int64 = MaxInflateOutput): tuple[data: seq[byte];
        next: int] {.contractual.} =
  ## Inflate a raw DEFLATE stream from `start` under an explicit output bound.
  require:
    start >= 0 and start <= data.len
    maxOutput > 0
  ensure:
    int64(result.data.len) <= maxOutput
    result.next >= start and result.next <= data.len
  body:
    try:
      result = uc.inflateWithConsumed(data, start, maxOutput)
    except uc.UniCompressException as error:
      raise mapError(error)

proc inflate*(data: openArray[byte]; start = 0;
    maxOutput: int64 = MaxInflateOutput): seq[byte] =
  ## Inflate a raw DEFLATE stream and discard its ending byte position.
  try:
    uc.inflate(data, start, maxOutput)
  except uc.UniCompressException as error:
    raise mapError(error)

proc compress*(data: openArray[byte]): seq[byte] =
  ## Compress `data` as a deterministic fixed-Huffman DEFLATE stream.
  uc.compress(data)
