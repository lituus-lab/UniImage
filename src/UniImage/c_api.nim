# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## C ABI for UniImage. Built --app:staticlib/--app:lib --noMain --mm:arc -d:release.
##
## Exposes EXIF/XMP/IPTC (`ui_exif_*`) and image codec/process
## (`ui_image_*`) surfaces. Keep this module in sync with
## `include/UniImage.h`; `tests/c` links the header.
##
## Conventions (see the header for the authoritative contract):
##   * Call `ui_exif_init()` exactly once per process before anything else
##     (it runs the Nim runtime initialiser).
##   * Handles are opaque `void*`. The library owns them; free with the matching
##     `*_free`. Returned `const char*` point into the handle and stay valid
##     until that handle is freed.
##   * No Nim exception or Defect crosses the ABI: every entry point traps both
##     and maps them to an error code.
import std/[tables, algorithm, sets, locks]
import ../UniImage

when defined(danger):
  {.warning: "libUniImage built with -d:danger: bounds checks are off and the " &
    "Defect backstops at the ABI boundary cannot fire. Prefer -d:release for a " &
    "hardened parser facing untrusted input.".}

const UniImageExifAbiVersion = 1

type
  TagPair = object
    name, value: string
  MetaHandle = ref object
    valid: bool
    orientation: int
    hasGps: bool
    lat, lon, alt: float
    camera, software: string
    tags: seq[TagPair]
    index: Table[string, int]
    json: string
    jsonBuilt: bool
  EditHandle = ref object
    path: string    # set for file-backed edits (ui_exif_edit_open)
    orig: seq[byte] # set for buffer-backed edits (ui_exif_edit_open_buffer)
    data: ExifData

# Status codes — keep in sync with `ui_exif_status` in UniImage.h.
const
  UI_EXIF_OK = cint(0)
  UI_EXIF_ERR_IO = cint(1)
  UI_EXIF_ERR_FORMAT = cint(2)
  UI_EXIF_ERR_UNSUP = cint(4)

proc NimMain() {.importc.}

proc metaOf(p: pointer): MetaHandle {.inline.} = cast[MetaHandle](p)
proc editOf(p: pointer): EditHandle {.inline.} = cast[EditHandle](p)

var
  handleLock: Lock
  metaHandles, editHandles, imageHandles, paletteHandles: HashSet[pointer]

initLock(handleLock)

proc registerHandle(handles: var HashSet[pointer]; h: pointer) =
  withLock handleLock:
    handles.incl h

proc containsHandle(handles: var HashSet[pointer]; h: pointer): bool =
  if h == nil: return false
  withLock handleLock:
    result = h in handles

proc unregisterHandle(handles: var HashSet[pointer]; h: pointer): bool =
  if h == nil: return false
  withLock handleLock:
    result = h in handles
    if result: handles.excl h

proc buildMetaHandle(m: Metadata): MetaHandle =
  ## Snapshot a parsed Metadata into a stable, C-owned handle (tags sorted; the
  ## strings live in the handle so returned `const char*` stay valid until free).
  result = MetaHandle(valid: m.isValid, orientation: m.orientation,
                      camera: m.cameraModel, software: m.software)
  if m.gpsLatitudeRef in {'N', 'S'} and m.gpsLongitudeRef in {'E', 'W'}:
    result.hasGps = true
    result.lat = m.gpsLatitude
    result.lon = m.gpsLongitude
    result.alt = m.gpsAltitude
  var keys: seq[string]
  for k in m.allTags.keys: keys.add k
  keys.sort()
  for k in keys:
    result.index[k] = result.tags.len
    result.tags.add TagPair(name: k, value: m.allTags[k])

{.push cdecl, exportc, dynlib.}

proc ui_exif_init() =
  ## Initialise the Nim runtime. Must be called once before any other function.
  try:
    NimMain()
  except CatchableError, Defect:
    discard

proc ui_exif_abi_version(): cint = cint(UniImageExifAbiVersion)

proc ui_exif_strerror(code: cint): cstring =
  case code
  of 0: cstring"ok"
  of 1: cstring"io error"
  of 2: cstring"unrecognized format / no metadata"
  of 4: cstring"unsupported operation"
  else: cstring"unknown error"

# --- read ------------------------------------------------------------------

proc ui_exif_read_file(path: cstring; outHandle: ptr pointer): cint =
  ## Parse metadata from `path`. On success stores an opaque handle (free with
  ## ui_exif_meta_free) and returns UI_EXIF_OK even when the file carries no
  ## metadata (check ui_exif_is_valid). Returns UI_EXIF_ERR_IO on failure.
  if path == nil or outHandle == nil: return UI_EXIF_ERR_FORMAT
  outHandle[] = nil
  try:
    let h = buildMetaHandle(readMetadata($path))
    let p = cast[pointer](h)
    registerHandle(metaHandles, p)
    GC_ref(h)
    outHandle[] = p
    UI_EXIF_OK
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_read_buffer(data: ptr uint8; length: csize_t;
    outHandle: ptr pointer): cint =
  ## Parse metadata from an in-memory buffer the caller owns (not copied).
  ## Same contract as ui_exif_read_file. The buffer need only outlive this call.
  if outHandle == nil: return UI_EXIF_ERR_FORMAT
  outHandle[] = nil
  if data == nil or length == 0 or length > csize_t(high(
      int)): return UI_EXIF_ERR_FORMAT
  try:
    let arr = cast[ptr UncheckedArray[byte]](data)
    let h = buildMetaHandle(readMetadataFromBytes(arr.toOpenArray(0, int(
        length) - 1)))
    let p = cast[pointer](h)
    registerHandle(metaHandles, p)
    GC_ref(h)
    outHandle[] = p
    UI_EXIF_OK
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_is_valid(h: pointer): cint =
  if not containsHandle(metaHandles, h): return 0
  if metaOf(h).valid: 1 else: 0

proc ui_exif_tag_count(h: pointer): csize_t =
  if not containsHandle(metaHandles, h): return 0
  csize_t(metaOf(h).tags.len)

proc ui_exif_tag_at(h: pointer; i: csize_t; name, value: ptr cstring): cint =
  ## Name/value of the i-th tag (0-based, sorted). Pointers are owned by `h`.
  if not containsHandle(metaHandles, h) or name == nil or value == nil:
    return UI_EXIF_ERR_FORMAT
  if i > csize_t(high(int)): return UI_EXIF_ERR_FORMAT
  let hh = metaOf(h)
  if int(i) >= hh.tags.len: return UI_EXIF_ERR_FORMAT
  name[] = cstring(hh.tags[int(i)].name)
  value[] = cstring(hh.tags[int(i)].value)
  UI_EXIF_OK

proc ui_exif_get_tag(h: pointer; key: cstring): cstring =
  ## Value of tag `key`, or NULL if absent. Pointer is owned by `h`.
  if not containsHandle(metaHandles, h) or key == nil: return nil
  try:
    let hh = metaOf(h)
    let k = $key
    if hh.index.hasKey(k): cstring(hh.tags[hh.index[k]].value) else: nil
  except CatchableError, Defect:
    nil

proc ui_exif_get_gps(h: pointer; lat, lon, alt: ptr cdouble): cint =
  ## 1 and fills the provided (non-NULL) out-params if GPS is present, else 0.
  if not containsHandle(metaHandles, h): return 0
  let hh = metaOf(h)
  if not hh.hasGps: return 0
  if lat != nil: lat[] = cdouble(hh.lat)
  if lon != nil: lon[] = cdouble(hh.lon)
  if alt != nil: alt[] = cdouble(hh.alt)
  1

proc ui_exif_get_orientation(h: pointer): cint =
  ## Raw EXIF Orientation (1..8), or 0 if absent.
  if not containsHandle(metaHandles, h): return 0
  cint(metaOf(h).orientation)

proc ui_exif_to_json(h: pointer): cstring =
  ## Pretty-printed JSON view (built lazily, cached). Pointer owned by `h`.
  if not containsHandle(metaHandles, h): return nil
  try:
    let hh = metaOf(h)
    if not hh.jsonBuilt:
      var mm: Metadata
      mm.isValid = hh.valid
      mm.orientation = hh.orientation
      mm.cameraModel = hh.camera
      mm.software = hh.software
      if hh.hasGps:
        mm.gpsLatitude = hh.lat
        mm.gpsLongitude = hh.lon
        mm.gpsAltitude = hh.alt
        mm.gpsLatitudeRef = if hh.lat >= 0: 'N' else: 'S'
        mm.gpsLongitudeRef = if hh.lon >= 0: 'E' else: 'W'
      for tp in hh.tags: mm.allTags[tp.name] = tp.value
      hh.json = metaToJson(mm)
      hh.jsonBuilt = true
    cstring(hh.json)
  except CatchableError, Defect:
    nil

proc ui_exif_meta_free(h: pointer) =
  if unregisterHandle(metaHandles, h): GC_unref(metaOf(h))

# --- strip -----------------------------------------------------------------

proc ui_exif_strip_file(inPath, outPath: cstring): cint =
  ## Copy `inPath` to `outPath` without metadata (JPEG/PNG/WebP/HEIC/AVIF).
  if inPath == nil or outPath == nil: return UI_EXIF_ERR_FORMAT
  try:
    if stripMetadata($inPath, $outPath): UI_EXIF_OK else: UI_EXIF_ERR_UNSUP
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_strip_buffer(data: ptr uint8; length: csize_t;
                          outData: ptr ptr uint8; outLen: ptr csize_t): cint =
  ## Strip metadata in memory. On success allocates *outData (free it with
  ## ui_exif_buffer_free) and sets *outLen. UI_EXIF_ERR_UNSUP if the container is
  ## unsupported/malformed; the input buffer is never modified.
  if outData == nil or outLen == nil: return UI_EXIF_ERR_FORMAT
  outData[] = nil
  outLen[] = 0
  if data == nil or length == 0 or length > csize_t(high(
      int)): return UI_EXIF_ERR_FORMAT
  try:
    let arr = cast[ptr UncheckedArray[byte]](data)
    let stripped = stripMetadataBytes(arr.toOpenArray(0, int(length) - 1))
    if stripped.len == 0: return UI_EXIF_ERR_UNSUP
    let buf = allocShared(stripped.len) # C-owned; freed by buffer_free
    if buf == nil: return UI_EXIF_ERR_IO
    copyMem(buf, unsafeAddr stripped[0], stripped.len)
    outData[] = cast[ptr uint8](buf)
    outLen[] = csize_t(stripped.len)
    UI_EXIF_OK
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_buffer_free(buffer: ptr uint8) =
  ## Free a buffer returned by ui_exif_strip_buffer. NULL is a no-op.
  if buffer != nil: deallocShared(buffer)

# --- edit / write ----------------------------------------------------------

proc ui_exif_edit_open(path: cstring; outHandle: ptr pointer): cint =
  if path == nil or outHandle == nil: return UI_EXIF_ERR_FORMAT
  outHandle[] = nil
  try:
    var e = EditHandle(path: $path)
    e.data = parseExif($path)
    let p = cast[pointer](e)
    registerHandle(editHandles, p)
    GC_ref(e)
    outHandle[] = p
    UI_EXIF_OK
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_edit_open_buffer(data: ptr uint8; length: csize_t;
    outHandle: ptr pointer): cint =
  ## Open an editable EXIF model from an in-memory buffer (the caller owns the
  ## bytes; they are copied into the handle so the input need only outlive this
  ## call). Mutate with the ui_exif_set_* / ui_exif_strip_all functions, then
  ## serialize with ui_exif_edit_write_buffer. Free with ui_exif_edit_free.
  if outHandle == nil: return UI_EXIF_ERR_FORMAT
  outHandle[] = nil
  if data == nil or length == 0 or length > csize_t(high(
      int)): return UI_EXIF_ERR_FORMAT
  try:
    let arr = cast[ptr UncheckedArray[byte]](data)
    var e = EditHandle()
    e.orig = newSeq[byte](int(length))
    copyMem(addr e.orig[0], data, int(length))
    e.data = parseExifBytes(arr.toOpenArray(0, int(length) - 1))
    let p = cast[pointer](e)
    registerHandle(editHandles, p)
    GC_ref(e)
    outHandle[] = p
    UI_EXIF_OK
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_set_artist(h: pointer; v: cstring) =
  if not containsHandle(editHandles, h) or v == nil: return
  try:
    editOf(h).data.setArtist($v)
  except CatchableError, Defect:
    discard

proc ui_exif_set_software(h: pointer; v: cstring) =
  if not containsHandle(editHandles, h) or v == nil: return
  try:
    editOf(h).data.setSoftware($v)
  except CatchableError, Defect:
    discard

proc ui_exif_set_datetime(h: pointer; v: cstring) =
  ## Expects "YYYY:MM:DD HH:MM:SS".
  if not containsHandle(editHandles, h) or v == nil: return
  try:
    editOf(h).data.setDateTimeOriginal($v)
  except CatchableError, Defect:
    discard

proc ui_exif_set_gps(h: pointer; lat, lon, alt: cdouble) =
  if not containsHandle(editHandles, h): return
  try:
    editOf(h).data.setGps(float(lat), float(lon), float(alt))
  except CatchableError, Defect:
    discard

proc ui_exif_edit_set_tag(h: pointer; name, value: cstring): cint =
  ## Generic write: set EXIF tag `name` to `value` (parsed into the tag's natural
  ## type). Returns UI_EXIF_OK, or UI_EXIF_ERR_UNSUP for an unknown tag / bad value.
  if not containsHandle(editHandles, h) or name == nil or value == nil:
    return UI_EXIF_ERR_FORMAT
  try:
    if editOf(h).data.setTagByName($name,
        $value): UI_EXIF_OK else: UI_EXIF_ERR_UNSUP
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_strip_all(h: pointer) =
  if not containsHandle(editHandles, h): return
  try:
    editOf(h).data.stripAll()
  except CatchableError, Defect:
    discard

proc ui_exif_edit_write(h: pointer; outPath: cstring): cint =
  ## Write the edited EXIF. If `outPath` is NULL/empty, writes in place. Only
  ## file-backed handles (from ui_exif_edit_open) can write to disk; buffer-backed
  ## handles must use ui_exif_edit_write_buffer.
  if not containsHandle(editHandles, h): return UI_EXIF_ERR_FORMAT
  try:
    let eh = editOf(h)
    if eh.path.len == 0: return UI_EXIF_ERR_FORMAT # buffer-backed handle
    let dst = if outPath == nil or outPath[0] == '\0': eh.path else: $outPath
    if writeExif(eh.path, eh.data, dst): UI_EXIF_OK else: UI_EXIF_ERR_UNSUP
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_edit_write_buffer(h: pointer; outData: ptr ptr uint8;
    outLen: ptr csize_t): cint =
  ## Serialize the edited EXIF back into the bytes the handle was opened from and
  ## return the new image buffer. On success allocates *outData (free it with
  ## ui_exif_buffer_free) and sets *outLen. UI_EXIF_ERR_UNSUP if the container is
  ## unsupported/too large; UI_EXIF_ERR_FORMAT if the handle is not buffer-backed.
  if outData == nil or outLen == nil: return UI_EXIF_ERR_FORMAT
  outData[] = nil
  outLen[] = 0
  if not containsHandle(editHandles, h): return UI_EXIF_ERR_FORMAT
  let eh = editOf(h)
  if eh.orig.len == 0: return UI_EXIF_ERR_FORMAT # opened via path, not a buffer
  try:
    let output = writeExifBytes(eh.orig, eh.data)
    if output.len == 0: return UI_EXIF_ERR_UNSUP
    let buf = allocShared(output.len) # C-owned; freed by buffer_free
    if buf == nil: return UI_EXIF_ERR_IO
    copyMem(buf, unsafeAddr output[0], output.len)
    outData[] = cast[ptr uint8](buf)
    outLen[] = csize_t(output.len)
    UI_EXIF_OK
  except CatchableError, Defect:
    UI_EXIF_ERR_IO

proc ui_exif_edit_free(h: pointer) =
  if unregisterHandle(editHandles, h): GC_unref(editOf(h))

proc ui_version(): cstring =
  ## Static engine version string; do not free.
  cstring(UniImageVersion)

# ============================================================================
# ui_image_* — codec + process surface
# ----------------------------------------------------------------------------
# Opaque `ui_image` handles wrap an `Image[uint8]` the library owns; free with
# `ui_image_free`. `ui_image_pixels` borrows the pixel buffer (no copy) — valid
# until the handle is freed. Encode allocates a C-owned buffer (free with
# `ui_image_buffer_free`). Every entry validates handles/lengths and traps
# CatchableError + Defect -> a ui_image_status code; no Nim exception or Defect
# crosses the boundary. Keep in sync with the ui_image_* block in UniImage.h.
# ============================================================================

const UniImageImageAbiVersion = 1

type
  ImgHandle = ref object
    img: Image[uint8]
  PaletteHandle = ref object
    palette: Palette
  UiColor {.bycopy.} = object
    comps: array[4, cfloat]
    tag: int32
  UiQuantizeOpts {.bycopy.} = object
    seed: int64
    maxIter: cint
    weighting: cint
    parallel: cint
    threads: cint

proc imgOf(p: pointer): ImgHandle {.inline.} = cast[ImgHandle](p)
proc paletteOf(p: pointer): PaletteHandle {.inline.} = cast[PaletteHandle](p)

proc toUiColor(color: quantize.Color): UiColor {.inline, raises: [].} =
  UiColor(comps: [color.comp(0), color.comp(1), color.comp(2), color.alpha],
      tag: color.spaceTag.id)

# Status codes — keep in sync with `ui_image_status` in UniImage.h.
const
  UI_IMAGE_OK = cint(0)
  UI_IMAGE_ERR_FORMAT = cint(2) # bad arg / unrecognized / truncated / bad handle
  UI_IMAGE_ERR_UNSUP = cint(4)  # unsupported format/colorspace/op
  UI_IMAGE_ERR_MEM = cint(8)    # allocation failed

# Format hint / encode target — keep in sync with `ui_image_format`.
const
  UI_IMAGE_FMT_AUTO = cint(0)  # decode only: sniff the magic
  UI_IMAGE_FMT_PNG = cint(1)
  UI_IMAGE_FMT_JPEG = cint(2)
  UI_IMAGE_FMT_BMP = cint(3)
  UI_IMAGE_FMT_QOI = cint(4)
  UI_IMAGE_FMT_PNM = cint(5)
  UI_IMAGE_FMT_GIF = cint(6)   # decode only (no encoder)
  UI_IMAGE_FMT_PCX = cint(7)   # decode only (no encoder)
  UI_IMAGE_FMT_TGA = cint(8)   # decode only (no magic; needs the hint)
  UI_IMAGE_FMT_WEBP = cint(9)  # decode only (no encoder yet)
  UI_IMAGE_FMT_TIFF = cint(10) # decode only (no encoder yet)

# Resize filter — keep in sync with `ui_image_filter`.
const
  UI_IMAGE_FILTER_NEAREST = cint(0)
  UI_IMAGE_FILTER_BILINEAR = cint(1)
  UI_IMAGE_FILTER_BOX = cint(2)

# Rotate/flip op — keep in sync with `ui_image_rotate_op`.
const
  UI_IMAGE_ROT_90 = cint(0)
  UI_IMAGE_ROT_180 = cint(1)
  UI_IMAGE_ROT_270 = cint(2)
  UI_IMAGE_FLIP_H = cint(3)
  UI_IMAGE_FLIP_V = cint(4)

# Colorspace — keep in sync with `ui_image_colorspace`. The order matches the
# Nim `Colorspace` enum (core.nim), so `ord` maps directly.
const
  UI_IMAGE_CS_GRAY = cint(0)
  UI_IMAGE_CS_RGB = cint(1)
  UI_IMAGE_CS_RGBA = cint(2)
  UI_IMAGE_CS_CMYK = cint(3)
  UI_IMAGE_CS_YUV = cint(4)
  UI_IMAGE_CS_INDEXED = cint(5)

proc mapImgStatus(code: UniImageError): cint {.inline.} =
  case code
  of uiUnsupported: UI_IMAGE_ERR_UNSUP
  of uiOk: UI_IMAGE_OK
  else: UI_IMAGE_ERR_FORMAT # truncated / invalidArg / encoding / io

proc encodeFmtFromCint(fmt: cint): EncodeFormat =
  case fmt
  of UI_IMAGE_FMT_PNG: efPng
  of UI_IMAGE_FMT_JPEG: efJpeg
  of UI_IMAGE_FMT_BMP: efBmp
  of UI_IMAGE_FMT_QOI: efQoi
  of UI_IMAGE_FMT_PNM: efPnm
  of UI_IMAGE_FMT_TGA: efTga
  else:
    raise UniImageException(code: uiUnsupported,
        msg: "ui_image_encode: not an encodable format")

proc filterFromCint(f: cint): ResizeFilter =
  case f
  of UI_IMAGE_FILTER_NEAREST: rfNearest
  of UI_IMAGE_FILTER_BILINEAR: rfBilinear
  of UI_IMAGE_FILTER_BOX: rfBox
  else:
    raise UniImageException(code: uiInvalidArg, msg: "ui_image: bad filter")

proc rotateOpFromCint(op: cint): RotateOp =
  case op
  of UI_IMAGE_ROT_90: rot90
  of UI_IMAGE_ROT_180: rot180
  of UI_IMAGE_ROT_270: rot270
  of UI_IMAGE_FLIP_H: flipH
  of UI_IMAGE_FLIP_V: flipV
  else:
    raise UniImageException(code: uiInvalidArg, msg: "ui_image: bad rotate op")

proc ui_image_abi_version(): cint = cint(UniImageImageAbiVersion)

proc ui_image_strerror(code: cint): cstring =
  case code
  of 0: cstring"ok"
  of 2: cstring"bad argument / unrecognized / truncated"
  of 4: cstring"unsupported operation"
  of 8: cstring"out of memory"
  else: cstring"unknown error"

proc ui_image_from_pixels(width, height, colorspace: cint; data: ptr uint8;
    length: csize_t; outHandle: ptr pointer): cint =
  ## Build an owned image by copying a packed 8-bit pixel buffer.
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if width <= 0 or height <= 0 or colorspace < UI_IMAGE_CS_GRAY or
      colorspace > UI_IMAGE_CS_INDEXED:
    return UI_IMAGE_ERR_FORMAT
  let cs = cast[Colorspace](int(colorspace))
  let channels = ChannelCount[cs]
  if int(width) > high(int) div int(height): return UI_IMAGE_ERR_FORMAT
  let pixels = int(width) * int(height)
  if pixels > high(int) div channels: return UI_IMAGE_ERR_FORMAT
  let expected = pixels * channels
  if data == nil or length != csize_t(expected): return UI_IMAGE_ERR_FORMAT
  try:
    var image = newImage[uint8](int(width), int(height), cs)
    let source = cast[ptr UncheckedArray[uint8]](data)
    for i in 0 ..< expected:
      image.data[i] = source[i]
    let handle = ImgHandle(img: image)
    let p = cast[pointer](handle)
    registerHandle(imageHandles, p)
    GC_ref(handle)
    outHandle[] = p
    UI_IMAGE_OK
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_decode_buffer(data: ptr uint8; length: csize_t; fmt: cint;
    outHandle: ptr pointer): cint =
  ## Decode an in-memory image. `fmt=UI_IMAGE_FMT_AUTO` sniffs the magic
  ## (PNG/JPEG/BMP/QOI/PNM/GIF/PCX/WebP/TIFF); `UI_IMAGE_FMT_TGA`/`WEBP`/`TIFF`
  ## decode those formats directly (TGA has no magic; the others skip sniffing).
  ## On success stores an opaque handle (free with ui_image_free).
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if data == nil or length == 0 or length > csize_t(high(int)):
    return UI_IMAGE_ERR_FORMAT
  if fmt < UI_IMAGE_FMT_AUTO or fmt > UI_IMAGE_FMT_TIFF:
    return UI_IMAGE_ERR_FORMAT
  try:
    let arr = cast[ptr UncheckedArray[byte]](data)
    let img =
      case fmt
      of UI_IMAGE_FMT_TGA: decodeTga(arr.toOpenArray(0, int(length) - 1))
      of UI_IMAGE_FMT_WEBP: decodeWebp(arr.toOpenArray(0, int(length) - 1))
      of UI_IMAGE_FMT_TIFF: decodeTiff(arr.toOpenArray(0, int(length) - 1))
      else: decodeImage(arr.toOpenArray(0, int(length) - 1))
    let h = ImgHandle(img: img)
    let p = cast[pointer](h)
    registerHandle(imageHandles, p)
    GC_ref(h)
    outHandle[] = p
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_thumbnail(data: ptr uint8; length: csize_t;
    outHandle: ptr pointer): cint =
  ## Decode the embedded EXIF JPEG thumbnail (IFD1, tags 513/514) from any
  ## supported container (JPEG, TIFF/RAW, HEIC/AVIF/MP4/MOV, PNG, WebP) into an
  ## 8-bit image, without a full container decode. On success stores an opaque
  ## handle (free with ui_image_free). `UI_IMAGE_ERR_UNSUP` when the container
  ## has no EXIF segment or no embedded thumbnail.
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if data == nil or length == 0 or length > csize_t(high(int)):
    return UI_IMAGE_ERR_FORMAT
  try:
    let arr = cast[ptr UncheckedArray[byte]](data)
    let img = loadThumbnail(arr.toOpenArray(0, int(length) - 1))
    let h = ImgHandle(img: img)
    let p = cast[pointer](h)
    registerHandle(imageHandles, p)
    GC_ref(h)
    outHandle[] = p
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_encode(h: pointer; fmt: cint; quality: cint;
    outData: ptr ptr uint8; outLen: ptr csize_t): cint =
  ## Encode the image as `fmt` (PNG/JPEG/BMP/QOI/PNM/TGA). `quality` (1..100)
  ## applies to JPEG only. On success allocates *outData (free with
  ## ui_image_buffer_free) and sets *outLen.
  if outData == nil or outLen == nil: return UI_IMAGE_ERR_FORMAT
  outData[] = nil
  outLen[] = 0
  if not containsHandle(imageHandles, h): return UI_IMAGE_ERR_FORMAT
  try:
    let hh = imgOf(h)
    let ef = encodeFmtFromCint(fmt)
    let q = min(100, max(1, int(quality)))
    let bytes = encodeImage(hh.img, ef, q)
    if bytes.len == 0: return UI_IMAGE_ERR_UNSUP
    let buf = allocShared(bytes.len) # C-owned; freed by buffer_free
    if buf == nil: return UI_IMAGE_ERR_MEM
    copyMem(buf, unsafeAddr bytes[0], bytes.len)
    outData[] = cast[ptr uint8](buf)
    outLen[] = csize_t(bytes.len)
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_width(h: pointer): cint =
  if not containsHandle(imageHandles, h): return 0
  cint(imgOf(h).img.width)

proc ui_image_height(h: pointer): cint =
  if not containsHandle(imageHandles, h): return 0
  cint(imgOf(h).img.height)

proc ui_image_channels(h: pointer): cint =
  if not containsHandle(imageHandles, h): return 0
  cint(imgOf(h).img.channels)

proc ui_image_get_colorspace(h: pointer): cint =
  if not containsHandle(imageHandles, h): return UI_IMAGE_CS_GRAY
  cint(ord(imgOf(h).img.colorspace))

proc ui_image_pixels(h: pointer; outPtr: ptr ptr uint8;
    outLen: ptr csize_t): cint =
  ## Borrow the pixel buffer (no copy). *outPtr is valid until `h` is freed.
  if outPtr == nil or outLen == nil: return UI_IMAGE_ERR_FORMAT
  outPtr[] = nil
  outLen[] = 0
  if not containsHandle(imageHandles, h): return UI_IMAGE_ERR_FORMAT
  let hh = imgOf(h)
  if hh.img.data.len == 0: return UI_IMAGE_OK # empty but valid
  outPtr[] = cast[ptr uint8](addr hh.img.data[0])
  outLen[] = csize_t(hh.img.data.len)
  UI_IMAGE_OK

proc ui_image_resize(h: pointer; w, height: cint; filter: cint;
    outHandle: ptr pointer): cint =
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if not containsHandle(imageHandles, h) or w <= 0 or height <= 0:
    return UI_IMAGE_ERR_FORMAT
  try:
    let rf = filterFromCint(filter)
    let dst = resize(imgOf(h).img, int(w), int(height), rf)
    let nh = ImgHandle(img: dst)
    let p = cast[pointer](nh)
    registerHandle(imageHandles, p)
    GC_ref(nh)
    outHandle[] = p
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_crop(h: pointer; x, y, w, height: cint;
    outHandle: ptr pointer): cint =
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if not containsHandle(imageHandles, h): return UI_IMAGE_ERR_FORMAT
  try:
    let dst = crop(imgOf(h).img, int(x), int(y), int(w), int(height))
    let nh = ImgHandle(img: dst)
    let p = cast[pointer](nh)
    registerHandle(imageHandles, p)
    GC_ref(nh)
    outHandle[] = p
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_rotate(h: pointer; op: cint; outHandle: ptr pointer): cint =
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if not containsHandle(imageHandles, h): return UI_IMAGE_ERR_FORMAT
  try:
    let r = rotateOpFromCint(op)
    let dst = rotate(imgOf(h).img, r)
    let nh = ImgHandle(img: dst)
    let p = cast[pointer](nh)
    registerHandle(imageHandles, p)
    GC_ref(nh)
    outHandle[] = p
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_apply_orientation(h: pointer; orientation: cint;
    outHandle: ptr pointer): cint =
  ## Apply an EXIF Orientation value (1..8) to a decoded image. The returned
  ## handle owns an independent pixel buffer, including for orientation 1.
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if not containsHandle(imageHandles, h) or orientation < 1 or orientation > 8:
    return UI_IMAGE_ERR_FORMAT
  try:
    let dst = applyExifOrientation(imgOf(h).img, int(orientation))
    let nh = ImgHandle(img: dst)
    let p = cast[pointer](nh)
    registerHandle(imageHandles, p)
    GC_ref(nh)
    outHandle[] = p
    UI_IMAGE_OK
  except UniImageException as e:
    mapImgStatus(e.code)
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_image_extract_palette(h: pointer; n: cint; algo: cstring;
    space: int32; opts: ptr UiQuantizeOpts; outHandle: ptr pointer): cint =
  ## Extract a UniColor palette. NULL `algo`, space 0 and NULL `opts` select
  ## UniColor's deterministic defaults.
  if outHandle == nil: return UI_IMAGE_ERR_FORMAT
  outHandle[] = nil
  if not containsHandle(imageHandles, h) or n < 1:
    return UI_IMAGE_ERR_FORMAT
  try:
    let algorithm = if algo == nil: DefaultQuantizeAlgo else: $algo
    let workSpace = if space == 0: DefaultQuantizeSpace else: SpaceTag(space)
    var options = defaultQuantizeOpts()
    if opts != nil:
      options = QuantizeOpts(seed: opts[].seed, maxIter: int(opts[].maxIter),
          weighting: opts[].weighting != 0, parallel: opts[].parallel != 0,
          threads: int(opts[].threads))
    let extracted = extractPalette(imgOf(h).img, int(n), algorithm, workSpace,
        options)
    if extracted.isErr:
      case extracted.error.kind
      of ColorErrorKind.UnknownAlgorithm, ColorErrorKind.UnknownSpace:
        return UI_IMAGE_ERR_UNSUP
      else:
        return UI_IMAGE_ERR_FORMAT
    let palette = PaletteHandle(palette: extracted.get)
    let p = cast[pointer](palette)
    registerHandle(paletteHandles, p)
    GC_ref(palette)
    outHandle[] = p
    UI_IMAGE_OK
  except CatchableError, Defect:
    UI_IMAGE_ERR_FORMAT

proc ui_palette_len(h: pointer): csize_t =
  if not containsHandle(paletteHandles, h): return 0
  csize_t(paletteOf(h).palette.len)

proc ui_palette_color_at(h: pointer; i: csize_t; outColor: ptr UiColor): cint =
  if outColor == nil or not containsHandle(paletteHandles, h) or
      i > csize_t(high(int)):
    return UI_IMAGE_ERR_FORMAT
  let colors = paletteOf(h).palette.colors
  if int(i) >= colors.len: return UI_IMAGE_ERR_FORMAT
  outColor[] = colors[int(i)].toUiColor
  UI_IMAGE_OK

proc ui_palette_tag(h: pointer): cint =
  if not containsHandle(paletteHandles, h): return 0
  cint(ord(paletteOf(h).palette.tag))

proc ui_palette_intent(h: pointer): cint =
  if not containsHandle(paletteHandles, h): return 0
  cint(ord(paletteOf(h).palette.intent))

proc ui_palette_seed(h: pointer): int64 =
  if not containsHandle(paletteHandles, h): return 0
  paletteOf(h).palette.seed

proc ui_palette_free(h: pointer) =
  if unregisterHandle(paletteHandles, h): GC_unref(paletteOf(h))

proc ui_image_free(h: pointer) =
  if unregisterHandle(imageHandles, h): GC_unref(imgOf(h))

proc ui_image_buffer_free(p: ptr uint8; len: csize_t) =
  ## Free a buffer returned by ui_image_encode. NULL is a no-op. `len` is
  ## ignored (kept for symmetry with the allocator).
  if p != nil: deallocShared(p)

{.pop.}
