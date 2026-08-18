# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The ISO base media box layer: reading a tree of boxes, and building one.
##
## MP4, MOV, HEIF and AVIF are the same structure — a box is a length, a
## four-character kind and a payload, and boxes nest. What differs between them
## is which boxes they carry, never how a box is shaped, so one module walks all
## of them and each format's own module says what it is looking for.
##
## Nothing here interprets a payload. It finds boxes and hands over their spans;
## a caller reads what it came for.

const MaxBoxDepth* = 32
  ## Hard cap on ISOBMFF box nesting. Hostile files can chain thousands of
  ## `moov`/`meta` boxes; without a bound the recursive walk overflows the stack
  ## (a SIGSEGV that `try/except CatchableError` does NOT catch). 32 is far
  ## beyond any real file (a few levels: ftyp/moov/trak/mdia/minf/...).

type
  Box* = object
    offset*: int
    size*: int64
    kind*: string

func beU32(data: openArray[byte]; offset: int): uint32 =
  ## Four big-endian bytes. Out of range reads as 0, which every caller here
  ## turns into a rejected box rather than trusting.
  if offset < 0 or offset + 3 >= data.len: return 0
  (uint32(data[offset]) shl 24) or (uint32(data[offset + 1]) shl 16) or
    (uint32(data[offset + 2]) shl 8) or uint32(data[offset + 3])

func beU64(data: openArray[byte]; offset: int): uint64 =
  ## Eight big-endian bytes, for a box whose 32-bit size was the escape value 1.
  if offset < 0 or offset + 7 >= data.len: return 0
  (uint64(beU32(data, offset)) shl 32) or uint64(beU32(data, offset + 4))

proc readBoxHeader*(data: openArray[byte]; offset: int): Box =
  if offset < 0 or offset > data.len - 8: return
  let size32 = beU32(data, offset)
  result.offset = offset
  result.size = int64(size32)
  result.kind = ""
  for i in 0..3: result.kind.add char(data[offset + 4 + i])

  if size32 == 1:
    if offset + 16 <= data.len:
      let hi = beU32(data, offset + 8)
      let lo = beU32(data, offset + 12)
      result.size = (int64(hi) shl 32) or int64(lo)

iterator boxes*(data: openArray[byte]; start, limit: int): tuple[kind: string;
    body, bodyEnd: int] =
  ## Each box between `start` and `limit`, as its kind and the span of its
  ## payload.
  ##
  ## A size of 0 means "to the end of the enclosing box"; 1 means a 64-bit size
  ## follows the kind, which moves the payload eight bytes further along. A box
  ## claiming to be smaller than its own header, or to run past its parent, ends
  ## the walk rather than raising: trailing garbage after a valid box should not
  ## cost a caller what it already parsed.
  ##
  ## The bound is the caller's, not the buffer's, so a nested walk cannot escape
  ## its parent — which is what makes recursion over this safe.
  var offset = start
  while offset >= 0 and offset + 8 <= limit and offset + 8 <= data.len:
    let box = readBoxHeader(data, offset)
    var size = box.size
    var header = if beU32(data, offset) == 1: 16 else: 8
    if size == 0: size = int64(limit - offset)
    if size < int64(header) or offset + int(size) > limit: break
    yield (box.kind, offset + header, offset + int(size))
    offset += int(size)

func putBE*(target: var string; value: int64; width: int) =
  ## Append `value` as `width` big-endian bytes. Bits above `width` are dropped,
  ## so a matrix entry can be written as four bytes and a volume as two without
  ## either being masked at the call site.
  ##
  ## The building half of this module: the same box structure these procs read
  ## is what `box` and `fullBox` assemble, so a file written here reads back
  ## through `boxes` above.
  for index in countdown(width - 1, 0):
    target.add char(uint8((value shr (index * 8)) and 0xFF))

func box*(kind: string; payload: string): string =
  ## A box: its own length, its four-character kind, then its payload.
  result.putBE(int64(payload.len + 8), 4)
  result.add kind
  result.add payload

func fullBox*(kind: string; payload: string): string =
  ## A full box — one whose payload begins with a version byte and three flag
  ## bytes. Both are zero for everything ISOBMFF needs written here.
  box(kind, "\0\0\0\0" & payload)

proc findBox*(data: openArray[byte]; start, limit: int;
              path: openArray[string]; depth = 0): tuple[body, bodyEnd: int] =
  ## Walk a path of box kinds, e.g. `["moov", "trak", "mdia"]`, and return the
  ## span of the last one's payload. `(-1, -1)` when any step is missing, so a
  ## caller tests one value rather than catching an exception for a box that is
  ## legitimately optional.
  ##
  ## `MaxBoxDepth` bounds the recursion: a file whose sizes describe a cycle
  ## stops here rather than running the stack out.
  if depth > MaxBoxDepth or path.len == 0: return (-1, -1)
  for kind, body, bodyEnd in boxes(data, start, limit):
    if kind != path[0]: continue
    if path.len == 1: return (body, bodyEnd)
    let inner = findBox(data, body, bodyEnd, path[1 .. ^1], depth + 1)
    if inner.body >= 0: return inner
  (-1, -1)

proc isIsobmff*(data: openArray[byte]): bool =
  data.len >= 12 and data[4] == byte('f') and data[5] == byte('t') and
    data[6] == byte('y') and data[7] == byte('p')
