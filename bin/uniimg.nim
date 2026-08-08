# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## uniimg — UniImage command-line inspector/editor.
##
##   uniimg show   <file> [--json]      dump all metadata (text or JSON)
##   uniimg audit  <file>               privacy report (GPS, camera, dates...)
##   uniimg xmp    <file>               show XMP (title/keywords/creator...)
##   uniimg strip  <in> [out]           remove all metadata
##   uniimg thumb  <file> <out> [--decode]  extract the embedded thumbnail (raw, or --decode to rasterize)
##   uniimg set    <file> [options]     edit EXIF (writes in place unless --out)
##       --artist=NAME  --software=NAME  --datetime="YYYY:MM:DD HH:MM:SS"
##       --gps=LAT,LON[,ALT]  --out=PATH
##   uniimg convert <in> <out> [--quality N]  transcode (PNG/JPEG/BMP/QOI/PNM/TGA)
import std/[os, strutils, tables, algorithm, strformat]
import UniImage/exif
import UniImage/formats
import UniImage/process
from UniImage import loadThumbnail

proc die(msg: string) =
  stderr.writeLine "error: " & msg
  quit(1)

proc needFile(path: string) =
  if not fileExists(path): die("file not found: " & path)

proc loadInputBytes(inPath, outPath: string): seq[byte] =
  # Shared by convert/resize/crop/rotate: refuse to clobber the input, confirm
  # it exists, then slurp it into a byte seq.
  if outPath == inPath: die("refusing to overwrite the input; choose a different output")
  needFile(inPath)
  let raw = readFile(inPath)
  result = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc hasGps(m: Metadata): bool =
  m.gpsLatitudeRef in {'N', 'S'} and m.gpsLongitudeRef in {'E', 'W'}

# --- show ------------------------------------------------------------------

proc cmdShow(path: string, asJson = false) =
  needFile(path)
  let m = readMetadata(path)
  if asJson:
    echo metaToJson(m)
    return
  echo "File:     ", path
  echo "Size:     ", formatSize(getFileSize(path))
  if not m.isValid:
    echo "\n[info] no EXIF/XMP/IPTC metadata found."
    return
  if m.cameraModel.len > 0: echo "Camera:   ", m.cameraModel
  if m.software.len > 0: echo "Software: ", m.software
  if hasGps(m):
    echo &"GPS:      {m.gpsLatitude:.6f}, {m.gpsLongitude:.6f}" &
         (if m.gpsAltitude != 0.0: &"  ({m.gpsAltitude:.1f} m)" else: "")
  let thumb = readThumbnail(path)
  if thumb.len > 0: echo "Thumbnail: ", formatSize(thumb.len), " embedded"
  echo "\n--- tags (", m.allTags.len, ") ---"
  var keys: seq[string]
  for k in m.allTags.keys: keys.add k
  keys.sort()
  for k in keys:
    echo k.alignLeft(28), ": ", m.allTags[k]

# --- xmp -------------------------------------------------------------------

proc cmdXmp(path: string) =
  needFile(path)
  let x = readXmp(path)
  var any = false
  template line(label, val: untyped) =
    if val.len > 0: echo label.alignLeft(12), ": ", val; any = true
  line("Title", x.title)
  line("Description", x.description)
  line("Rights", x.rights)
  line("Creator", x.creator.join(", "))
  line("Keywords", x.keywords.join(", "))
  if not any: echo "[info] no XMP packet found."

# --- audit -----------------------------------------------------------------

proc cmdAudit(path: string) =
  needFile(path)
  let m = readMetadata(path)
  let x = readXmp(path)
  let ip = readIptc(path)
  let thumb = readThumbnail(path)
  echo "Privacy audit: ", path
  var flags = 0
  template warn(msg: string) =
    echo "  [!] " & msg; inc flags
  template note(msg: string) =
    echo "  [-] " & msg

  if hasGps(m):
    warn(&"GPS location present: {m.gpsLatitude:.6f}, {m.gpsLongitude:.6f}")
    echo &"        https://www.openstreetmap.org/?mlat={m.gpsLatitude:.6f}&mlon={m.gpsLongitude:.6f}#map=16/{m.gpsLatitude:.5f}/{m.gpsLongitude:.5f}"
  if m.cameraModel.len > 0:
    warn("Camera identified: " & m.cameraModel)
  if m.software.len > 0:
    note("Software: " & m.software)
  let shotDate = m.allTags.getOrDefault("DateTimeOriginal")
  if shotDate.len > 0:
    note("Capture timestamp: " & shotDate)
  let artist = m.allTags.getOrDefault("Artist")
  if artist.len > 0: warn("Author (EXIF Artist): " & artist)
  if ip.byline.len > 0: warn("Author (IPTC By-line): " & ip.byline.join(", "))
  if x.creator.len > 0: warn("Author (XMP Creator): " & x.creator.join(", "))
  let copy = m.allTags.getOrDefault("Copyright")
  if copy.len > 0: note("Copyright: " & copy)
  if thumb.len > 0:
    warn("Embedded thumbnail (" & formatSize(thumb.len) &
         ") — may retain the original, uncropped framing")

  echo ""
  if flags == 0:
    echo "Verdict: clean — no obvious identifying metadata."
  else:
    echo "Verdict: ", flags, " privacy-sensitive item(s). Run `strip` before sharing."

# --- strip -----------------------------------------------------------------

proc cmdStrip(args: seq[string]) =
  if args.len < 1: die("usage: strip <in> [out]")
  let inPath = args[0]
  needFile(inPath)
  let outPath =
    if args.len >= 2: args[1]
    else:
      let (dir, name, ext) = splitFile(inPath)
      dir / (name & ".clean" & ext)
  if outPath == inPath: die("refusing to overwrite the input; choose a different output")
  if stripMetadata(inPath, outPath):
    echo "stripped -> ", outPath
  else:
    die("could not strip (unsupported container?): " & inPath)

# --- thumb -----------------------------------------------------------------

proc cmdThumb(args: seq[string]) =
  # `uniimg thumb <file> <out> [--decode]`: by default write the raw embedded
  # EXIF thumbnail bytes (a JPEG, so a .jpg out is a usable file). With --decode,
  # rasterize it via loadThumbnail and encode to the output extension, so a
  # HEIC/AVIF/RAW preview can be extracted without a full container decode.
  if args.len < 2: die("usage: thumb <file> <out> [--decode]")
  var decode = false
  var pos: seq[string]
  for a in args:
    if a == "--decode": decode = true
    elif a.startsWith("--"): die("unexpected argument: " & a)
    else: pos.add(a)
  if pos.len < 2: die("usage: thumb <file> <out> [--decode]")
  let (inPath, outPath) = (pos[0], pos[1])
  if outPath == inPath:
    die("refusing to overwrite the input; choose a different output")
  needFile(inPath)
  if not decode:
    let thumb = readThumbnail(inPath)
    if thumb.len == 0: die("no embedded thumbnail in " & inPath)
    writeFile(outPath, cast[string](thumb))
    echo "wrote ", formatSize(thumb.len), " -> ", outPath
  else:
    let raw = readFile(inPath)
    var bytes = newSeq[byte](raw.len)
    if raw.len > 0: copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
    let (_, _, outExt) = splitFile(outPath)
    try:
      let img = loadThumbnail(bytes)
      let out8 = encodeImage(img, encodeFormatFromExt(outExt), 90)
      writeFile(outPath, cast[string](out8))
      echo "decoded thumbnail ", img.width, "x", img.height, " -> ", outPath
    except UniImageException as e:
      die(e.msg)

# --- set -------------------------------------------------------------------

proc cmdSet(args: seq[string]) =
  if args.len < 1: die("usage: set <file> [--artist= --software= --datetime= --gps= --out=]")
  let path = args[0]
  needFile(path)
  var e = parseExif(path)
  var outPath = path
  var exifChanged = false
  var iptcItems: seq[(string, string)]
  for a in args[1 .. ^1]:
    if not a.startsWith("--"): die("unexpected argument: " & a)
    let kv = a[2 .. ^1].split('=', 1)
    if kv.len != 2: die("expected --key=value, got: " & a)
    let (key, val) = (kv[0], kv[1])
    case key
    of "artist": e.setArtist(val); exifChanged = true
    of "software": e.setSoftware(val); exifChanged = true
    of "datetime": e.setDateTimeOriginal(val); exifChanged = true
    of "gps":
      let parts = val.split(',')
      if parts.len notin {2, 3}: die("--gps expects LAT,LON[,ALT]")
      var lat, lon, alt: float
      try:
        lat = parseFloat(parts[0].strip())
        lon = parseFloat(parts[1].strip())
        alt = if parts.len == 3: parseFloat(parts[2].strip()) else: 0.0
      except ValueError:
        die("--gps expects numeric LAT,LON[,ALT]")
      e.setGps(lat, lon, alt)
      exifChanged = true
    of "out": outPath = val
    else:
      if key.startsWith("IPTC:"): # IPTC dataset, e.g. --IPTC:Keywords=sea
        iptcItems.add (key[5 .. ^1], val)
      elif e.setTagByName(key, val): exifChanged = true # generic EXIF tag by name
      else: die("unknown tag or bad value: --" & key &
                "\nwritable tags: " & writableTagNames().join(", "))
  if not exifChanged and iptcItems.len == 0: die("nothing to set")
  # Stage the output in a temp file beside outPath and replace it only on
  # success, so a mid-way failure (bad EXIF, non-JPEG for IPTC) leaves the
  # destination untouched rather than a half-written file.
  let tmp = outPath & ".uniimg.tmp"
  if exifChanged:
    if not writeExif(path, e, tmp):
      discard tryRemoveFile(tmp)
      die("could not write EXIF (EXIF block too large, or unsupported container)")
  if iptcItems.len > 0:
    let src = if exifChanged: tmp else: path
    let raw = readFile(src)
    var bytes = newSeq[byte](raw.len)
    if raw.len > 0: copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
    let outp = setIptcInJpeg(bytes, iptcItems)
    if outp.len == 0:
      discard tryRemoveFile(tmp)
      die("IPTC write requires a JPEG")
    writeFile(tmp, cast[string](outp))
  moveFile(tmp, outPath)
  echo "wrote -> ", outPath

# --- convert ----------------------------------------------------------------

proc cmdConvert(args: seq[string]) =
  # `uniimg convert <in> <out> [--quality N]`: decode the input by sniffing its
  # magic (TGA has none, so it is dispatched by extension), then encode via the
  # output path's extension. JPEG is the only lossy target; --quality is
  # ignored for the lossless codecs.
  if args.len < 2: die("usage: convert <in> <out> [--quality N]")
  let inPath = args[0]
  let outPath = args[1]
  var quality = 90
  for a in args[2 .. ^1]:
    if a.startsWith("--quality="):
      try: quality = parseInt(a[10 .. ^1])
      except ValueError: die("--quality expects an integer 1..100")
      if quality notin 1..100: die("--quality must be 1..100")
    else: die("unexpected argument: " & a)
  let bytes = loadInputBytes(inPath, outPath)
  let (_, _, inExt) = splitFile(inPath)
  # TGA carries no reliable header magic, so dispatch it by extension; the
  # other formats are sniffed from their bytes by `decodeImage`. Codec errors
  # (unsupported format, truncated input, bad header) raise UniImageException;
  # route them through `die` so a failed convert looks like any other CLI error
  # instead of an uncaught-exception stack trace.
  try:
    let img =
      if inExt.toLowerAscii() in [".tga", ".targa"]: decodeTga(bytes)
      else: decodeImage(bytes)
    let (_, _, outExt) = splitFile(outPath)
    let out8 = encodeImage(img, encodeFormatFromExt(outExt), quality)
    writeFile(outPath, cast[string](out8))
    echo "converted ", formatSize(bytes.len), " -> ", formatSize(out8.len),
        "  ", outPath
  except UniImageException as e:
    die(e.msg)

# --- resize -----------------------------------------------------------------

proc parseDims(s: string): (int, int) =
  # "WxH" (case-insensitive x). Both halves must be positive integers.
  let parts = s.toLowerAscii().split('x')
  if parts.len != 2: die("expected <W>x<H>, got: " & s)
  try:
    let w = parseInt(parts[0]); let h = parseInt(parts[1])
    if w <= 0 or h <= 0: die("dimensions must be positive: " & s)
    result = (w, h)
  except ValueError:
    die("expected integer dimensions, got: " & s)

proc decodeInput(inPath: string; bytes: seq[byte]): Image[uint8] =
  # Decode by sniffing the magic; TGA has none, so dispatch it by extension.
  let (_, _, inExt) = splitFile(inPath)
  if inExt.toLowerAscii() in [".tga", ".targa"]: decodeTga(bytes)
  else: decodeImage(bytes)

proc cmdResize(args: seq[string]) =
  # `uniimg resize <in> <out> <W>x<H> [--filter=nearest|bilinear|box]`.
  if args.len < 3: die("usage: resize <in> <out> <W>x<H> [--filter=nearest|bilinear|box]")
  let inPath = args[0]; let outPath = args[1]
  let (w, h) = parseDims(args[2])
  var filter = rfBilinear
  for a in args[3 .. ^1]:
    if a.startsWith("--filter="):
      case a[9 .. ^1]
      of "nearest": filter = rfNearest
      of "bilinear": filter = rfBilinear
      of "box": filter = rfBox
      else: die("--filter expects nearest|bilinear|box, got: " & a[9 .. ^1])
    else: die("unexpected argument: " & a)
  let bytes = loadInputBytes(inPath, outPath)
  try:
    let img = decodeInput(inPath, bytes)
    let out8 = encodeImage(resize(img, w, h, filter),
                           encodeFormatFromExt(splitFile(outPath).ext), 90)
    writeFile(outPath, cast[string](out8))
    echo "resized ", img.width, "x", img.height, " -> ", w, "x", h, "  ", outPath
  except UniImageException as e:
    die(e.msg)

# --- crop -------------------------------------------------------------------

proc parseRect(s: string): (int, int, int, int) =
  # "X,Y,WxH": top-left corner and sub-rect size. Split on ',' into X, Y, and
  # the "WxH" tail, then split the tail on 'x'.
  let parts = s.split(',')
  if parts.len != 3: die("expected <X>,<Y>,<W>x<H>, got: " & s)
  let dims = parts[2].toLowerAscii().split('x')
  if dims.len != 2: die("expected <X>,<Y>,<W>x<H>, got: " & s)
  try:
    let x = parseInt(parts[0]); let y = parseInt(parts[1])
    let w = parseInt(dims[0]); let h = parseInt(dims[1])
    if w <= 0 or h <= 0: die("crop size must be positive: " & s)
    result = (x, y, w, h)
  except ValueError:
    die("expected integer crop spec, got: " & s)

proc cmdCrop(args: seq[string]) =
  # `uniimg crop <in> <out> <X>,<Y>,<W>x<H>`.
  if args.len < 3: die("usage: crop <in> <out> <X>,<Y>,<W>x<H>")
  let inPath = args[0]; let outPath = args[1]
  let (x, y, w, h) = parseRect(args[2])
  if args.len > 3: die("unexpected argument: " & args[3])
  let bytes = loadInputBytes(inPath, outPath)
  try:
    let img = decodeInput(inPath, bytes)
    let out8 = encodeImage(crop(img, x, y, w, h),
                           encodeFormatFromExt(splitFile(outPath).ext), 90)
    writeFile(outPath, cast[string](out8))
    echo "cropped to ", w, "x", h, " from (", x, ",", y, ")  ", outPath
  except UniImageException as e:
    die(e.msg)

# --- rotate -----------------------------------------------------------------

proc parseRotateOp(s: string): RotateOp =
  case s.toLowerAscii()
  of "90": result = rot90
  of "180": result = rot180
  of "270": result = rot270
  of "fliph": result = flipH
  of "flipv": result = flipV
  else: die("rotate expects 90|180|270|fliph|flipv, got: " & s)

proc cmdRotate(args: seq[string]) =
  # `uniimg rotate <in> <out> <90|180|270|fliph|flipv>`.
  if args.len < 3: die("usage: rotate <in> <out> <90|180|270|fliph|flipv>")
  let inPath = args[0]; let outPath = args[1]
  let op = parseRotateOp(args[2])
  if args.len > 3: die("unexpected argument: " & args[3])
  let bytes = loadInputBytes(inPath, outPath)
  try:
    let img = decodeInput(inPath, bytes)
    let out8 = encodeImage(rotate(img, op),
                           encodeFormatFromExt(splitFile(outPath).ext), 90)
    writeFile(outPath, cast[string](out8))
    echo "rotated (", args[2], ")  ", outPath
  except UniImageException as e:
    die(e.msg)

# --- dispatch --------------------------------------------------------------

proc usage() =
  echo """uniimg — UniImage EXIF/XMP/IPTC inspector and editor

  show   <file> [--json]       dump all metadata (text, or machine-readable JSON)
  audit  <file>                privacy report (GPS, camera, author, thumbnail)
  xmp    <file>                show XMP fields
  strip  <in> [out]            remove all metadata
  thumb  <file> <out> [--decode]  extract the embedded thumbnail (raw, or --decode to rasterize)
  set    <file> [options]      edit EXIF (in place unless --out=PATH)
         --artist=NAME --software=NAME --datetime="YYYY:MM:DD HH:MM:SS"
         --gps=LAT,LON[,ALT] --out=PATH
  convert <in> <out> [--quality N]  transcode (PNG/JPEG/BMP/QOI/PNM/TGA)
  resize <in> <out> <W>x<H> [--filter=nearest|bilinear|box]
  crop   <in> <out> <X>,<Y>,<W>x<H>
  rotate <in> <out> <90|180|270|fliph|flipv>"""

proc main() =
  let args = commandLineParams()
  if args.len < 1: usage(); quit(1)
  let rest = args[1 .. ^1]
  case args[0]
  of "show":
    var file = ""
    var asJson = false
    for a in rest:
      if a == "--json": asJson = true
      elif not a.startsWith("--"): (if file.len == 0: file = a)
    if file.len == 0: die("usage: show <file> [--json]")
    cmdShow(file, asJson)
  of "audit": (if rest.len < 1: die("usage: audit <file>")); cmdAudit(rest[0])
  of "xmp": (if rest.len < 1: die("usage: xmp <file>")); cmdXmp(rest[0])
  of "strip": cmdStrip(rest)
  of "thumb": cmdThumb(rest)
  of "set": cmdSet(rest)
  of "convert": cmdConvert(rest)
  of "resize": cmdResize(rest)
  of "crop": cmdCrop(rest)
  of "rotate": cmdRotate(rest)
  of "-h", "--help", "help": usage()
  else: die("unknown command: " & args[0] & " (try `help`)")

when isMainModule:
  main()
