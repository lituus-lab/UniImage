# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## HEIF, and the HEIC and AVIF that are built on it: what the container says
## about a picture, without decoding one.
##
## A HEIF file has no image in the ordinary sense. It has *items*, each with an
## identifier, a location in the file and a set of properties; `pitm` names the
## one that is the picture, `iinf` lists them all, `ipco` holds every property
## any of them uses and `ipma` says which item uses which. So the size of the
## picture is found by following three indirections, not by reading a header.
##
## That indirection is the whole reason to do it properly: a photograph from a
## phone carries a thumbnail beside the full image, both with an `ispe`, and
## taking the first one gives the thumbnail's size.
##
## Nothing here decodes. The coded bytes are HEVC or AV1, and turning them into
## pixels belongs to a backend the application registers.

import ../isobmff

type
  HeifRotation* = enum
    ## Counter-clockwise display rotation, as `irot` stores it — the format's
    ## own direction, kept rather than converted so that what is reported is
    ## what the file says.
    heifRot0 = 0
    heifRot90 = 90
    heifRot180 = 180
    heifRot270 = 270

  HeifImage* = object
    ## What the container says about its primary picture.
    width*, height*: int
      ## The size to display, which is the coded size cropped by the clean
      ## aperture when the file carries one. libheif pads a picture out to a
      ## size the encoder likes and crops it back with `clap`, so reading
      ## `ispe` alone reports a 64x48 photograph as 64x64.
    codedWidth*, codedHeight*: int
      ## The size `ispe` declares, before any crop. Equal to `width` and
      ## `height` unless a clean aperture narrows them.
    rotation*: HeifRotation
    mirrored*: bool ## `imir`, applied after the rotation
    codec*: string
      ## The four-character code the picture is coded in — `hvc1` for HEIC,
      ## `av01` for AVIF. What a decoder backend is registered under.
    itemId*: int ## the primary item, as `pitm` names it
    dataOffset*, dataLength*: int
      ## Where the coded bytes are. Zero length when `iloc` describes the item
      ## in a way this reader does not follow — a construction method other
      ## than a plain file offset, or an item split into several extents.

const
  MaxItems = 4096
    ## More items than any photograph carries. A file claiming more is refused
    ## rather than allocated for.
  MaxProperties = 512

func isHeif*(data: openArray[byte]): bool =
  ## Whether these bytes are HEIF or one of its brands.
  ##
  ## The major brand is at offset 8, inside `ftyp`. `mif1` is the base brand,
  ## `heic`/`heix` are HEVC pictures, `avif` is AV1, and `msf1`/`hevc` appear on
  ## sequences. Anything else built on ISO base media — an MP4 — is not this.
  if data.len < 12: return false
  if not isIsobmff(data): return false
  var brand = ""
  for index in 8 .. 11: brand.add char(data[index])
  brand in ["mif1", "miaf", "heic", "heix", "hevc", "hevx", "avif", "avis",
            "msf1", "mif2"]

func beU16(data: openArray[byte]; at: int): int =
  if at < 0 or at + 1 >= data.len: return 0
  (int(data[at]) shl 8) or int(data[at + 1])

func beU32i(data: openArray[byte]; at: int): int =
  if at < 0 or at + 3 >= data.len: return 0
  (int(data[at]) shl 24) or (int(data[at + 1]) shl 16) or
    (int(data[at + 2]) shl 8) or int(data[at + 3])

func primaryItem(data: openArray[byte]; body, bodyEnd: int): int =
  ## `pitm`: which item is the picture. Version 0 names it in two bytes,
  ## version 1 in four.
  if body + 4 > bodyEnd: return -1
  let version = int(data[body])
  if version == 0:
    if body + 6 > bodyEnd: return -1
    beU16(data, body + 4)
  else:
    if body + 8 > bodyEnd: return -1
    beU32i(data, body + 4)

func itemCodec(data: openArray[byte]; body, bodyEnd: int; item: int): string =
  ## The coding of one item, from its `infe` entry in `iinf`.
  ##
  ## The item's type is a four-character code — `hvc1`, `av01`, `grid` for a
  ## tiled picture, `Exif` for the metadata item — and it is what says how the
  ## bytes at the item's location are coded.
  if body + 6 > bodyEnd: return ""
  let version = int(data[body])
  var at = body + (if version == 0: 6 else: 8)
  while at + 8 <= bodyEnd:
    let size = beU32i(data, at)
    if size < 8 or at + size > bodyEnd: break
    var kind = ""
    for index in 4 .. 7: kind.add char(data[at + index])
    if kind == "infe":
      let entryVersion = int(data[at + 8])
      let idAt = at + 12
      let id = if entryVersion >= 3: beU32i(data, idAt) else: beU16(data, idAt)
      if id == item:
        let typeAt = idAt + (if entryVersion >= 3: 4 else: 2) + 2
        if typeAt + 4 <= at + size:
          for index in 0 .. 3: result.add char(data[typeAt + index])
        return
    at += size


func propertyIndices(data: openArray[byte]; body, bodyEnd: int;
                     item: int): seq[int] =
  ## `ipma`: which properties the given item uses, as one-based indices into
  ## `ipco`.
  ##
  ## The index is six bits wide unless the flags say fifteen, and the item id is
  ## two bytes unless the version says four — both of which a phone and a
  ## desktop encoder disagree about, so both are read rather than assumed.
  if body + 8 > bodyEnd: return
  let version = int(data[body])
  let flags = (int(data[body + 1]) shl 16) or (int(data[body + 2]) shl 8) or
              int(data[body + 3])
  let wideIndex = (flags and 1) != 0
  let count = beU32i(data, body + 4)
  if count < 0 or count > MaxItems: return
  var at = body + 8
  for _ in 0 ..< count:
    let id = if version < 1: beU16(data, at) else: beU32i(data, at)
    at += (if version < 1: 2 else: 4)
    if at >= bodyEnd: return
    let associations = int(data[at])
    inc at
    for _ in 0 ..< associations:
      if at >= bodyEnd: return
      var index: int
      if wideIndex:
        index = beU16(data, at) and 0x7FFF
        at += 2
      else:
        index = int(data[at]) and 0x7F
        inc at
      if id == item and index > 0: result.add index

func readProperty(data: openArray[byte]; kind: string; body, bodyEnd: int;
                  image: var HeifImage) =
  ## One property from `ipco`, applied to the picture.
  case kind
  of "ispe":
    # Image spatial extent: the coded size, in a full box.
    if body + 12 <= bodyEnd:
      let width = beU32i(data, body + 4)
      let height = beU32i(data, body + 8)
      if width > 0 and height > 0:
        image.codedWidth = width
        image.codedHeight = height
        # Taken as the display size until a clean aperture says otherwise. The
        # properties arrive in the order `ipma` lists them, and `clap` follows
        # `ispe` in every writer seen, but the crop overwrites either way.
        if image.width == 0: image.width = width
        if image.height == 0: image.height = height
  of "clap":
    # Clean aperture: the part of the coded picture that is the picture. Four
    # rationals — width, height, and the two offsets, which do not change the
    # size and are not reported.
    if body + 16 <= bodyEnd:
      let widthN = beU32i(data, body)
      let widthD = beU32i(data, body + 4)
      let heightN = beU32i(data, body + 8)
      let heightD = beU32i(data, body + 12)
      if widthD > 0 and heightD > 0:
        let width = widthN div widthD
        let height = heightN div heightD
        if width > 0 and height > 0:
          image.width = width
          image.height = height
  of "irot":
    # Two bits, counting quarter turns anticlockwise.
    if body < bodyEnd:
      image.rotation = case int(data[body]) and 3
        of 1: heifRot90
        of 2: heifRot180
        of 3: heifRot270
        else: heifRot0
  of "imir":
    if body < bodyEnd: image.mirrored = true
  else: discard

func ilocField(data: openArray[byte]; width, position: int): int =
  ## One of `iloc`'s variable-width integers: zero, four or eight bytes wide,
  ## as the box's own header declared. A 64-bit value whose high half is set
  ## describes a file this cannot address, and reads as -1 so the caller
  ## refuses it rather than truncating.
  case width
  of 0: 0
  of 4: beU32i(data, position)
  of 8:
    if beU32i(data, position) != 0: -1 else: beU32i(data, position + 4)
  else: 0

func itemLocation(data: openArray[byte]; body, bodyEnd: int;
                  item: int): tuple[offset, length: int] =
  ## `iloc`: where an item's bytes are.
  ##
  ## Only the plain case is followed — construction method 0, one extent, sizes
  ## that fit in a machine int. A picture stored in several extents, or relative
  ## to another item, reports a zero length rather than a wrong offset.
  if body + 8 > bodyEnd: return
  let version = int(data[body])
  let sizes = int(data[body + 4])
  let offsetSize = (sizes shr 4) and 0xF
  let lengthSize = sizes and 0xF
  let baseSize = int(data[body + 5]) shr 4
  let indexSize = if version >= 1: int(data[body + 5]) and 0xF else: 0
  var at = body + 6
  var count: int
  if version < 2:
    count = beU16(data, at); at += 2
  else:
    count = beU32i(data, at); at += 4
  if count < 0 or count > MaxItems: return

  for _ in 0 ..< count:
    let id = if version < 2: beU16(data, at) else: beU32i(data, at)
    at += (if version < 2: 2 else: 4)
    if version >= 1:
      let method0 = beU16(data, at) and 0xF
      at += 2
      if id == item and method0 != 0: return # not a plain file offset
    at += 2 # data reference index
    let base = ilocField(data, baseSize, at)
    at += baseSize
    let extents = beU16(data, at)
    at += 2
    for extent in 0 ..< extents:
      at += indexSize
      let offset = ilocField(data, offsetSize, at)
      at += offsetSize
      let length = ilocField(data, lengthSize, at)
      at += lengthSize
      if id == item and extent == 0:
        if offset < 0 or length < 0 or extents != 1: return
        return (base + offset, length)
    if at > bodyEnd: return

proc readHeif*(data: openArray[byte]): HeifImage =
  ## What a HEIF file says about its primary picture: its size, its display
  ## rotation, how it is coded and where its bytes are.
  ##
  ## Structure only — no coded byte is touched, so the cost is the size of
  ## `meta` rather than of the file. Raises `ValueError` when the bytes are not
  ## HEIF or carry no primary item.
  if not isHeif(data):
    raise newException(ValueError, "heif: not a HEIF file")
  let meta = findBox(data, 0, data.len, ["meta"])
  if meta.body < 0:
    raise newException(ValueError, "heif: no meta box")
  # `meta` is a full box: four bytes of version and flags before its children.
  let children = meta.body + 4

  for kind, body, bodyEnd in boxes(data, children, meta.bodyEnd):
    if kind == "pitm":
      result.itemId = primaryItem(data, body, bodyEnd)
  if result.itemId <= 0:
    raise newException(ValueError, "heif: no primary item")

  for kind, body, bodyEnd in boxes(data, children, meta.bodyEnd):
    case kind
    of "iinf":
      result.codec = itemCodec(data, body, bodyEnd, result.itemId)
    of "iloc":
      let place = itemLocation(data, body, bodyEnd, result.itemId)
      result.dataOffset = place.offset
      result.dataLength = place.length
    of "iprp":
      # The properties the primary item uses, in the order `ipma` lists them.
      var wanted: seq[int]
      for inner, innerBody, innerEnd in boxes(data, body, bodyEnd):
        if inner == "ipma":
          wanted = propertyIndices(data, innerBody, innerEnd, result.itemId)
      if wanted.len == 0 or wanted.len > MaxProperties: continue
      for inner, innerBody, innerEnd in boxes(data, body, bodyEnd):
        if inner != "ipco": continue
        var index = 0
        for propertyKind, propertyBody, propertyEnd in
            boxes(data, innerBody, innerEnd):
          inc index
          if index in wanted:
            readProperty(data, propertyKind, propertyBody, propertyEnd, result)
    else: discard

  if result.width <= 0 or result.height <= 0:
    raise newException(ValueError, "heif: the primary item declares no size")

proc readHeifFile*(path: string): HeifImage =
  ## `readHeif` over a file.
  let data = readFile(path)
  var bytes = newSeq[byte](data.len)
  for index in 0 ..< data.len: bytes[index] = byte(data[index])
  readHeif(bytes)
