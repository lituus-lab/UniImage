# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## EXIF/XMP/IPTC metadata reader and editor for still/video containers.
##
## Migrated from nim-exif (Apache-2.0) into the UniImage `exif/` subpackage.
## Metadata-only: no pixel decode happens here. Supports JPEG, TIFF/RAW
## (NEF/CR2/DNG/ARW), PNG, WebP, and ISOBMFF (MP4/MOV/HEIC/AVIF).
import ./exif/[endian, tiff, jpeg, isobmff, tags, enums, png, webp, makernotes]
# The ISOBMFF box layer is the container primitive UniMovie builds tracks on;
# exporting it is what keeps one box reader in the family instead of two.
export isobmff
import ./exif/edit
export edit
import ./exif/xmp
export xmp
import ./exif/iptc
export iptc
import ./exif/thumbnail
export thumbnail
import std/[os, tables, times, strutils, math, json]

type
  Metadata* = object
    creationDate*: DateTime
    cameraModel*: string
    software*: string
    isValid*: bool         # Strictly means embedded metadata was found
    orientation*: int      # Raw EXIF Orientation value (1-8), -1 if absent
    gpsLatitude*: float
      # Decimal degrees, already signed: south is negative. 0.0 if absent.
      # EXIF keeps the magnitude and the hemisphere apart; these two are the
      # two put together, so applying the reference again flips the sign.
    gpsLongitude*: float # Decimal degrees, already signed: west is negative.
    gpsLatitudeRef*: char # 'N' or 'S', as the file stored it.
    gpsLongitudeRef*: char # 'E' or 'W', as the file stored it.
    gpsAltitude*: float # metres; negative below sea level
    allTags*: Table[string, string]

proc parseDateTime*(s: string): DateTime =
  let formats = [
    "yyyy:MM:dd HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy:MM:dd",
    "yyyy-MM-dd"
  ]
  for f in formats:
    try:
      let res = parse(s, f)
      if res.year >= 1900: return res
    except CatchableError: discard
  # Return a valid but old DateTime to avoid AssertionDefect on uninitialized access
  return dateTime(1899, mJan, 1, 0, 0, 0)

proc parseMP4Time(time: uint32): DateTime =
  let epoch = dateTime(1904, mJan, 1, 0, 0, 0, zone = utc())
  result = epoch + seconds(int64(time))

proc applyVideoMeta(meta: var Metadata; videoMeta: VideoMeta) =
  ## Fold a parsed ISOBMFF/MP4 `moov` result into the flat metadata view.
  if videoMeta.make != "": meta.allTags["Make"] = videoMeta.make
  if videoMeta.model != "": meta.allTags["Model"] = videoMeta.model
  if videoMeta.software != "": meta.allTags["Software"] = videoMeta.software
  if videoMeta.width > 0: meta.allTags["ImageWidth"] = $videoMeta.width
  if videoMeta.height > 0: meta.allTags["ImageHeight"] = $videoMeta.height
  let res = videoMeta.creationTime
  if res.startsWith("MP4-Time-V0:"):
    let timeVal = try: uint32(parseUint(res[
        12..^1])) except CatchableError: 0'u32
    if timeVal > 0: # 0 is 1904-01-01, usually a placeholder
      meta.creationDate = parseMP4Time(timeVal)
      if meta.creationDate.year >= 1900: meta.isValid = true
  elif res.startsWith("MP4-Time-V1:"):
    let t = try: parseBiggestUint(res[12..^1]) except CatchableError: 0'u64
    if t > 0:
      let epoch = dateTime(1904, mJan, 1, 0, 0, 0, zone = utc())
      meta.creationDate = epoch + seconds(int64(t))
      if meta.creationDate.year >= 1900: meta.isValid = true
  elif res.startsWith("String:"):
    meta.creationDate = parseDateTime(res[7..^1])
    if meta.creationDate.year >= 1900: meta.isValid = true

proc parseGpsRationals(s: string): float =
  let parts = s.split(' ')
  var degs, mins, secs: float
  proc parseRational(r: string): float =
    let slash = r.find('/')
    if slash < 0:
      return try: parseFloat(r.strip()) except CatchableError: 0.0
    let num = try: r[0 ..< slash].strip().parseFloat() except CatchableError: 0.0
    let den = try: r[slash+1 ..< r.len].strip().parseFloat() except CatchableError: 1.0
    if den == 0: return 0.0
    result = num / den
  var idx = 0
  for p in parts:
    let t = p.strip()
    if t.len == 0: continue
    case idx:
    of 0: degs = parseRational(t)
    of 1: mins = parseRational(t)
    of 2: secs = parseRational(t)
    else: discard
    inc idx
  result = degs + mins / 60.0 + secs / 3600.0

proc formatGPSCoord(val: string; refChar: string): string =
  let parts = val.split(' ')
  if parts.len >= 3:
    return parts[0] & " deg " & parts[1] & "' " & parts[2] & "\" " & refChar
  return val

proc ratToFloat(s: string): float =
  ## First whitespace-separated rational/integer token of `s`, as a float.
  let t = s.split(' ')[0].strip()
  let slash = t.find('/')
  if slash < 0:
    return try: parseFloat(t) except CatchableError: 0.0
  let num = try: t[0 ..< slash].strip().parseFloat() except CatchableError: 0.0
  let den = try: t[slash+1 ..< t.len].strip().parseFloat() except CatchableError: 1.0
  if den == 0: return 0.0
  num / den

proc fmtNum(f: float; decimals = 3): string =
  ## Decimal with trailing zeros trimmed (3 -> "3", 1.7800 -> "1.78").
  result = formatFloat(f, ffDecimal, decimals)
  if '.' in result:
    while result.len > 0 and result[^1] == '0': result.setLen(result.len - 1)
    if result.len > 0 and result[^1] == '.': result.setLen(result.len - 1)

proc fmtShutter(apexTv: float): string =
  ## APEX ShutterSpeedValue -> exposure time, exiftool-style ("1/121", "2").
  let secs = pow(2.0, -apexTv)
  if secs <= 0: return fmtNum(secs)
  if secs < 1.0: return "1/" & $int(round(1.0 / secs))
  return fmtNum(secs)

proc formatTagValue(name: string; val: string; meta: Metadata): string =
  try:
    case name:
      of "Orientation": return getOrientation(parseInt(val))
      of "ResolutionUnit": return getResolutionUnit(parseInt(val))
      of "ExposureProgram": return getExposureProgram(parseInt(val))
      of "MeteringMode": return getMeteringMode(parseInt(val))
      of "LightSource": return getLightSource(parseInt(val))
      of "Flash": return parseFlash(parseInt(val))
      of "WhiteBalance": return getWhiteBalance(parseInt(val))
      of "ColorSpace": return getColorSpace(parseInt(val.split(' ')[0]))
      of "ExposureMode": return getExposureMode(parseInt(val.split(' ')[0]))
      of "SceneCaptureType": return getSceneCaptureType(parseInt(val.split(' ')[0]))
      of "SensingMethod": return getSensingMethod(parseInt(val.split(' ')[0]))
      of "FNumber", "ApertureValue", "MaxApertureValue":
        # ApertureValue/MaxApertureValue are APEX; FNumber is already an f-number.
        let f = if name == "FNumber": ratToFloat(val)
                else: pow(2.0, ratToFloat(val) / 2.0)
        return "f/" & fmtNum(f, 2)
      of "DNGVersion", "DNGBackwardVersion":
        # 4 BYTEs (rendered as hex tokens by toString) -> "1.1.0.0"
        var parts: seq[string]
        for tok in val.split(' '):
          if tok.len > 0: parts.add $parseHexInt(tok)
        return parts.join(".")
      of "TIFF-EPStandardID":
        var parts: seq[string]
        for tok in val.split(' '):
          if tok.len > 0: parts.add $parseHexInt(tok)
        return parts.join(".")
      of "ColorMatrix1", "ColorMatrix2", "CameraCalibration1",
         "CameraCalibration2", "AnalogBalance", "AsShotNeutral":
        # DNG rational arrays -> space-joined trimmed decimals (exiftool form).
        var parts: seq[string]
        for tok in val.split(' '):
          if tok.len == 0: continue
          let sl = tok.find('/')
          if sl <= 0: parts.add tok
          else:
            let nu = try: parseFloat(tok[0 ..< sl]) except CatchableError: 0.0
            let de = try: parseFloat(tok[sl+1 .. ^1]) except CatchableError: 1.0
            parts.add (if de == 0: "0" else: fmtNum(nu / de, 6))
        return parts.join(" ")
      of "ShutterSpeedValue": return fmtShutter(ratToFloat(val))
      of "ExposureTime":
        # exiftool form: "1/x" for fast speeds, else a 1-decimal value ("4", "0.5").
        let secs = ratToFloat(val)
        if secs > 0 and secs < 0.25001: return "1/" & $int(round(1.0 / secs))
        return fmtNum(secs, 1)
      of "FocalLength": return fmtNum(ratToFloat(val)) & " mm"
      of "FocalLengthIn35mmFormat": return fmtNum(ratToFloat(val)) & " mm"
      of "ExposureCompensation", "BrightnessValue", "DigitalZoomRatio":
        return fmtNum(ratToFloat(val), 2)
      of "GPSAltitude":
        let r = if meta.allTags.hasKey("GPSAltitudeRef"): " " & meta.allTags[
            "GPSAltitudeRef"] else: ""
        return fmtNum(ratToFloat(val), 1) & " m" & r
      of "GPSAltitudeRef":
        # A BYTE value of 0 ("Above Sea Level") renders as an empty string; treat
        # an unparseable/empty value as 0 since the tag is present.
        let n = try: parseInt(val.split(' ')[0]) except CatchableError: 0
        return getGpsAltitudeRef(n)
      of "GPSSpeed": return fmtNum(ratToFloat(val), 2)
      of "GPSLatitude":
        let refChar = if meta.allTags.hasKey("GPSLatitudeRef"): meta.allTags[
            "GPSLatitudeRef"] else: "N"
        return formatGPSCoord(val, refChar)
      of "GPSLongitude":
        let refChar = if meta.allTags.hasKey("GPSLongitudeRef"): meta.allTags[
            "GPSLongitudeRef"] else: "W"
        return formatGPSCoord(val, refChar)
      else: discard
  except CatchableError: discard
  return val

proc exifTiffBase*(data: openArray[byte]): int =
  ## Offset of the EXIF TIFF header (the II/MM position) within `data` for any
  ## supported container, or -1 when there is no EXIF segment. JPEG (APP1),
  ## TIFF/RAW (the file itself), ISOBMFF (HEIC/AVIF/MP4/MOV Exif item), PNG
  ## (eXIf), and WebP (EXIF chunk) are recognized. The thumbnail extractor and
  ## `loadThumbnail` use this so one path serves every container.
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8: # JPEG
    let blk = findExifAPP1(data)
    if blk.offset > 0: return blk.offset
    return -1
  if data.len >= 4 and ((data[0] == 0x49 and data[1] == 0x49 and
      data[2] == 0x2A and data[3] == 0x00) or (data[0] == 0x4D and
      data[1] == 0x4D and data[2] == 0x00 and data[3] == 0x2A)): # TIFF/RAW
    return 0
  if data.len >= 8 and ((data[4] == 0x66 and data[5] == 0x74 and
      data[6] == 0x79 and data[7] == 0x70) or (data[4] == 0x6D and
      data[5] == 0x6F and data[6] == 0x6F and data[7] == 0x76)): # ISOBMFF
    let s = findExifTiffInIsobmff(data)
    return if s > 0: s else: findExifInHEIC(data)
  if isPng(data):
    let s = findExifInPng(data)
    return if s > 0: s else: -1
  if isWebp(data):
    let s = findExifInWebp(data)
    return if s > 0: s else: -1
  -1

proc readMetadataFromBytes*(data: openArray[byte]): Metadata =
  ## Parse metadata from an in-memory image buffer (the caller owns the bytes).
  ## Same format coverage as `readMetadata`, operating purely on `data`; used by
  ## the C ABI and any caller that already holds the file in memory. For very
  ## large videos whose `moov` sits past what is in `data`, prefer `readMetadata`
  ## (it can seek the file).
  result.creationDate = dateTime(1899, mJan, 1, 0, 0, 0)
  if data.len < 2: return

  proc addIfdTags(meta: var Metadata; ifd: IFD; data: openArray[byte]; base: int) =
    var make = meta.allTags.getOrDefault("Make")
    var model = meta.allTags.getOrDefault("Model")
    if ifd.tags.hasKey(0x010f'u16): make = ifd.tags[0x010f'u16].toString()
    if ifd.tags.hasKey(0x0110'u16): model = ifd.tags[0x0110'u16].toString()
    for id, tag in ifd.tags:
      if id == 0x927c'u16:
        # MakerNote: decode into <Vendor>:* tags instead of a hex dump.
        if isAppleMakerNote(tag.rawBytes): # Apple: blob-relative offsets
          for k, v in parseAppleMakerNote(tag.rawBytes): meta.allTags[k] = v
          continue
        # Other vendors (e.g. Canon) use TIFF-base-relative offsets, so parse
        # from the full buffer at the MakerNote's absolute position with `base`.
        let mn = parseMakerNote(make, data, tag.dataOffset, base, tag.endian,
                                model)
        if mn.len > 0:
          for k, v in mn: meta.allTags[k] = v
          continue
        # unknown vendor: fall through to the generic "MakerNote" hex dump
      if id == 0xa005'u16:
        # InteropIFD pointer: follow it and surface its tags (exiftool does not
        # emit the structural pointer itself, so we don't either).
        let ioff = base + int(readUint32(tag.rawBytes, 0, tag.endian))
        if ioff >= 0 and ioff + 2 <= data.len:
          for iid, itag in readIFD(data, ioff, base, tag.endian).tags:
            case iid
            of 0x0001'u16: # InteropIndex (exiftool-style description)
              let s = itag.toString().strip()
              meta.allTags["InteropIndex"] =
                case s
                of "R98": "R98 - DCF basic file (sRGB)"
                of "THM": "THM - DCF thumbnail file"
                of "R03": "R03 - DCF option file (Adobe RGB)"
                else: s
            of 0x0002'u16: # InteropVersion (ASCII, e.g. "0100")
              let s = itag.toString().strip()
              if s.len > 0: meta.allTags["InteropVersion"] = s
            of 0x1001'u16: meta.allTags["RelatedImageWidth"] = itag.toString()
            of 0x1002'u16: meta.allTags["RelatedImageHeight"] = itag.toString()
            else: discard
        continue
      if ExifTags.hasKey(id):
        let name = ExifTags[id].name
        let rawVal = tag.toString()
        meta.allTags[name] = formatTagValue(name, rawVal, meta)
        case name:
        of "Orientation":
          try: meta.orientation = parseInt(
              rawVal) except CatchableError: discard
        of "Make":
          meta.cameraModel = rawVal
        of "Model":
          if meta.cameraModel.len > 0:
            meta.cameraModel = meta.cameraModel & " " & rawVal
          else:
            meta.cameraModel = rawVal
        of "Software":
          meta.software = rawVal
        else: discard
      else:
        meta.allTags["Unknown:0x" & id.toHex(4)] = tag.toString()

  proc addGpsTags(meta: var Metadata; ifd: IFD) =
    # ifd.tags is unordered; store the hemisphere/altitude refs first so that
    # coordinate and altitude formatting picks the correct letter/direction.
    for refId in [0x0001'u16, 0x0003'u16, 0x0005'u16]:
      if ifd.tags.hasKey(refId) and GpsTags.hasKey(refId):
        let nm = GpsTags[refId].name
        meta.allTags[nm] = formatTagValue(nm, ifd.tags[refId].toString(), meta)
    for id, tag in ifd.tags:
      if GpsTags.hasKey(id):
        let name = GpsTags[id].name
        let rawVal = tag.toString()
        meta.allTags[name] = formatTagValue(name, rawVal, meta)
        case name:
        of "GPSLatitude":
          meta.gpsLatitude = parseGpsRationals(rawVal)
        of "GPSLongitude":
          meta.gpsLongitude = parseGpsRationals(rawVal)
        of "GPSLatitudeRef":
          meta.gpsLatitudeRef = if rawVal.len > 0: rawVal[0] else: 'N'
        of "GPSLongitudeRef":
          meta.gpsLongitudeRef = if rawVal.len > 0: rawVal[0] else: 'E'
        of "GPSAltitude":
          meta.gpsAltitude = parseGpsRationals(rawVal) # single rational -> metres
        else: discard
      else:
        meta.allTags["GPS:Unknown:0x" & id.toHex(4)] = tag.toString()

  proc parseTiffAt(meta: var Metadata; data: openArray[byte]; base: int) =
    ## Parse a standalone TIFF block at `base` (IFD0 + Exif/GPS sub-IFDs).
    if base <= 0 or base >= data.len: return
    let endian = if char(data[base]) == 'I': LittleEndian else: BigEndian
    let firstIfdOffset = readUint32(data, base + 4, endian)
    if base + int(firstIfdOffset) + 2 > data.len: return
    let ifd0 = readIFD(data, base + int(firstIfdOffset), base, endian)
    meta.addIfdTags(ifd0, data, base)
    if ifd0.tags.len > 0: meta.isValid = true
    if ifd0.tags.hasKey(0x8769):
      let exifOff = readUint32(ifd0.tags[0x8769].rawBytes, 0, endian)
      if base + int(exifOff) + 2 <= data.len:
        let exifIfd = readIFD(data, base + int(exifOff), base, endian)
        meta.addIfdTags(exifIfd, data, base)
        if exifIfd.tags.hasKey(0x9003):
          let d = parseDateTime(exifIfd.tags[0x9003].toString())
          if d.year >= 1900: meta.creationDate = d
        elif exifIfd.tags.hasKey(0x9004):
          let d = parseDateTime(exifIfd.tags[0x9004].toString())
          if d.year >= 1900: meta.creationDate = d
    if ifd0.tags.hasKey(0x8825):
      let gpsOff = readUint32(ifd0.tags[0x8825].rawBytes, 0, endian)
      if base + int(gpsOff) + 2 <= data.len:
        meta.addGpsTags(readIFD(data, base + int(gpsOff), base, endian))

  # JPEG
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8:
    let blockInfo = findExifAPP1(data)
    if blockInfo.offset > 0:
      let tiffOffset = blockInfo.offset
      let endianChar = char(data[tiffOffset])
      let endian = if endianChar == 'I': LittleEndian else: BigEndian
      let firstIfdOffset = readUint32(data, tiffOffset + 4, endian)
      var currentIfdOffset = int(firstIfdOffset)
      var visited = initTable[int, bool]()
      while currentIfdOffset != 0 and currentIfdOffset < blockInfo.length:
        if visited.hasKey(currentIfdOffset): break
        visited[currentIfdOffset] = true
        if tiffOffset + currentIfdOffset + 2 > data.len: break
        let ifd = readIFD(data, tiffOffset + currentIfdOffset, tiffOffset, endian)
        result.addIfdTags(ifd, data, tiffOffset)
        if ifd.tags.len > 0: result.isValid = true # metadata found (date optional)
        if ifd.tags.hasKey(0x8769):
          let exifOff = readUint32(ifd.tags[0x8769].rawBytes, 0, endian)
          if tiffOffset + int(exifOff) + 2 <= data.len:
            let exifIfd = readIFD(data, tiffOffset + int(exifOff), tiffOffset, endian)
            result.addIfdTags(exifIfd, data, tiffOffset)
            if exifIfd.tags.hasKey(0x9003):
              let d = parseDateTime(exifIfd.tags[0x9003].toString())
              if d.year >= 1900:
                result.creationDate = d
                result.isValid = true
            elif exifIfd.tags.hasKey(0x9004):
              let d = parseDateTime(exifIfd.tags[0x9004].toString())
              if d.year >= 1900:
                result.creationDate = d
                result.isValid = true
        if ifd.tags.hasKey(0x8825):
          let gpsOff = readUint32(ifd.tags[0x8825].rawBytes, 0, endian)
          if tiffOffset + int(gpsOff) + 2 <= data.len:
            let gpsIfd = readIFD(data, tiffOffset + int(gpsOff), tiffOffset, endian)
            result.addGpsTags(gpsIfd)
        currentIfdOffset = int(ifd.nextIfdOffset)

  # TIFF / RAW (NEF, CR2, DNG, ARW, etc.)
  elif data.len >= 4 and ((data[0] == 0x49 and data[1] == 0x49 and data[2] == 0x2A and data[3] == 0x00) or
                          (data[0] == 0x4D and data[1] == 0x4D and data[2] ==
                              0x00 and data[3] == 0x2A)):
    let tiffOffset = 0
    let endianChar = char(data[tiffOffset])
    let endian = if endianChar == 'I': LittleEndian else: BigEndian
    let firstIfdOffset = readUint32(data, tiffOffset + 4, endian)
    var visited = initTable[int, bool]()
    var ifdsToProcess = @[int(firstIfdOffset)]

    while ifdsToProcess.len > 0:
      let offset = ifdsToProcess.pop()
      if offset == 0 or offset >= data.len: continue
      if visited.hasKey(offset): continue
      visited[offset] = true

      if tiffOffset + offset + 2 > data.len: continue
      let ifd = readIFD(data, tiffOffset + offset, tiffOffset, endian)
      result.addIfdTags(ifd, data, tiffOffset)
      if ifd.tags.len > 0: result.isValid = true # metadata found (date optional)

      if int(ifd.nextIfdOffset) > 0:
        ifdsToProcess.add(int(ifd.nextIfdOffset))

      # SubIFDs tag (0x014A) often contains EXIF/RAW data in NEF/CR2
      if ifd.tags.hasKey(0x014A):
        let tag = ifd.tags[0x014A]
        if tag.count > 0 and tag.rawBytes.len >= int(tag.count) * 4:
          for i in 0 ..< tag.count:
            let subOff = readUint32(tag.rawBytes, int(i) * 4, endian)
            if subOff > 0 and int(subOff) < data.len:
              ifdsToProcess.add(int(subOff))

      if ifd.tags.hasKey(0x8769):
        let exifOff = readUint32(ifd.tags[0x8769].rawBytes, 0, endian)
        if tiffOffset + int(exifOff) + 2 <= data.len:
          let exifIfd = readIFD(data, tiffOffset + int(exifOff), tiffOffset, endian)
          result.addIfdTags(exifIfd, data, tiffOffset)
          if exifIfd.tags.hasKey(0x9003):
            let d = parseDateTime(exifIfd.tags[0x9003].toString())
            if d.year >= 1900:
              result.creationDate = d
              result.isValid = true
          elif exifIfd.tags.hasKey(0x9004):
            let d = parseDateTime(exifIfd.tags[0x9004].toString())
            if d.year >= 1900:
              result.creationDate = d
              result.isValid = true
      if ifd.tags.hasKey(0x8825):
        let gpsOff = readUint32(ifd.tags[0x8825].rawBytes, 0, endian)
        if tiffOffset + int(gpsOff) + 2 <= data.len:
          let gpsIfd = readIFD(data, tiffOffset + int(gpsOff), tiffOffset, endian)
          result.addGpsTags(gpsIfd)

  # ISOBMFF (MP4/MOV/HEIC)
  elif (data.len >= 8) and ((data[4] == 0x66 and data[5] == 0x74 and data[6] == 0x79 and data[7] == 0x70) or
       (data[4] == 0x6d and data[5] == 0x6f and data[6] == 0x6f and data[7] == 0x76)):

    # Spec-correct iloc/iinf localization (matches the writer); fall back to the
    # byte scan only if there is no parseable file-offset Exif item.
    var exifStart = findExifTiffInIsobmff(data)
    if exifStart < 0:
      exifStart = findExifInHEIC(data)
    if exifStart > 0:
      result.parseTiffAt(data, exifStart)

    if not result.isValid:
      # Video (MP4/MOV) path: scan top-level boxes for `moov` within the buffer.
      var pos = 0
      while pos + 8 <= data.len:
        let size32 = readUint32(data, pos, BigEndian)
        var kind = ""
        for i in 4 .. 7: kind.add char(data[pos + i])
        let boxSize =
          if size32 == 1:
            if pos + 16 > data.len: break
            (int64(readUint32(data, pos + 8, BigEndian)) shl 32) or
              int64(readUint32(data, pos + 12, BigEndian))
          elif size32 == 0: int64(data.len - pos)
          else: int64(size32)
        if boxSize < 8: break
        if kind == "moov":
          let hdr = if size32 == 1: 16 else: 8
          let payStart = pos + hdr
          if payStart >= data.len: break
          let payLen = min(min(int(boxSize) - hdr, data.len - payStart), 5 *
              1024 * 1024)
          if payLen <= 0: break
          applyVideoMeta(result, parseIsobmff(data.toOpenArray(payStart,
              payStart + payLen - 1)))
          break
        pos += int(boxSize)

  # PNG (eXIf chunk = a raw TIFF block; plus tEXt chunks)
  elif isPng(data):
    parseTiffAt(result, data, findExifInPng(data))
    for (k, v) in pngTextChunks(data):
      result.allTags[k] = v
      result.isValid = true

  # WebP (RIFF EXIF chunk = a raw TIFF block)
  elif isWebp(data):
    parseTiffAt(result, data, findExifInWebp(data))

  # IPTC-IIM (JPEG APP13): surface caption/keywords/byline/copyright/location
  # in the flat view so tools see them without a second call.
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8:
    let ip = parseIptc(data)
    # Surface every decoded IPTC-IIM dataset by its exiftool/exiv2 name.
    for name, value in ip.all:
      if value.len > 0: result.allTags["IPTC:" & name] = value

  # XMP (JPEG APP1 / PNG iTXt / WebP chunk): surface every property as XMP:<prefix:local>.
  block:
    let xm = readXmpBytes(data)
    for key, value in xm.all:
      if value.len > 0: result.allTags["XMP:" & key] = value

  # Apply hemisphere/altitude signs once both the value and its Ref are known.
  if result.gpsLatitudeRef == 'S' and result.gpsLatitude > 0:
    result.gpsLatitude = -result.gpsLatitude
  if result.gpsLongitudeRef == 'W' and result.gpsLongitude > 0:
    result.gpsLongitude = -result.gpsLongitude
  if result.allTags.getOrDefault("GPSAltitudeRef") in ["1", "01",
      "Below Sea Level"] and
     result.gpsAltitude > 0:
    result.gpsAltitude = -result.gpsAltitude

const DefaultHeaderCap = 16 * 1024 * 1024
  ## Initial bounded read for `readMetadata`. EXIF/structure boxes live near the
  ## start, so this is normally ample; larger metadata reached only through a
  ## file offset (ISOBMFF `moov`, a HEIC/AVIF `Exif` item extent) is recovered by
  ## the seek-supplements below without loading the whole file.

proc readMetadata*(path: string; maxHeaderBytes = DefaultHeaderCap): Metadata =
  ## Reads and parses metadata from the file at `path`.
  ## Supports JPEG, TIFF/RAW, PNG, WebP, and ISOBMFF (MP4/MOV/HEIC/AVIF).
  ## `maxHeaderBytes` caps the initial in-memory read (default 16 MiB); pass a
  ## larger value to read more up front, or a smaller one to lean on the
  ## seek-supplements. Metadata reached via a file offset is found regardless.
  let fileSize = try: getFileSize(path) except CatchableError: 0'i64
  if fileSize == 0: return
  var f: File
  defer:
    if f != nil: close(f)
  var data: seq[byte]
  try:
    if not open(f, path): return
    let cap = if maxHeaderBytes < 16: 16 else: maxHeaderBytes
    let headerSize = min(int(fileSize), cap)
    data = newSeq[byte](headerSize)
    let bytesRead = f.readBuffer(addr data[0], headerSize)
    data.setLen(bytesRead)
  except CatchableError:
    return

  result = readMetadataFromBytes(data)

  # Large-video supplement: the `moov` box can live past the 16 MiB read cap, so
  # if an ISOBMFF file still has no metadata, seek the whole file for it.
  if (not result.isValid) and data.len >= 8 and int64(data.len) < fileSize and
     ((data[4] == 0x66 and data[5] == 0x74 and data[6] == 0x79 and data[7] ==
         0x70) or
      (data[4] == 0x6d and data[5] == 0x6f and data[6] == 0x6f and data[7] == 0x76)):
    try:
      f.setFilePos(0)
      var pos = 0'i64
      while pos + 8 <= fileSize:
        f.setFilePos(pos)
        var header: array[8, byte]
        if f.readBuffer(addr header[0], 8) != 8: break
        let size32 = readUint32(header, 0, BigEndian)
        var kind = ""
        for i in 4 .. 7: kind.add char(header[i])
        let boxSize = if size32 == 1:
          var extSize: array[8, byte]
          if f.readBuffer(addr extSize[0], 8) != 8: break
          (int64(readUint32(extSize, 0, BigEndian)) shl 32) or int64(readUint32(
              extSize, 4, BigEndian))
        elif size32 == 0: fileSize - pos else: int64(size32)
        if kind == "moov":
          let readSize = min(int(boxSize), 5 * 1024 * 1024)
          if readSize > 0:
            var moovContent = newSeq[byte](readSize)
            let n = f.readBuffer(addr moovContent[0], readSize)
            moovContent.setLen(n)
            applyVideoMeta(result, parseIsobmff(moovContent))
          break
        if boxSize <= 0: break
        pos += boxSize
    except CatchableError: discard

  # Large-image supplement: a HEIC/AVIF `Exif` item extent (located via meta/iloc,
  # which always sit at the start of the file) can point past the read cap into a
  # large `mdat`. The `meta`/`iloc` boxes are within the header window, so resolve
  # the extent there, then seek-read exactly those bytes — no need to load the
  # whole (potentially huge) file. Only runs when the capped read found nothing.
  if (not result.isValid) and data.len >= 8 and int64(data.len) < fileSize and
     data[4] == 0x66 and data[5] == 0x74 and data[6] == 0x79 and data[7] == 0x70:
    let loc = locateExifItem(data)
    if loc.found and loc.cmeth == 0 and loc.length > 4 and
       loc.off >= 0 and int64(loc.off) + int64(loc.length) <= fileSize and
       loc.off + loc.length > data.len: # extent lies beyond the read cap
      try:
        f.setFilePos(int64(loc.off))
        var ext = newSeq[byte](loc.length)
        let n = f.readBuffer(addr ext[0], loc.length)
        ext.setLen(n)
        if n >= 4:
          let tho = int(readUint32(ext, 0, BigEndian)) # exif_tiff_header_offset
          let tiffStart = 4 + tho
          if tho >= 0 and tiffStart + 1 < ext.len and
             (char(ext[tiffStart]) == 'I' or char(ext[tiffStart]) == 'M'):
            result = readMetadataFromBytes(ext.toOpenArray(tiffStart, ext.len - 1))
      except CatchableError: discard


# ---------------------------------------------------------------------------
# EXIF Orientation write (JPEG only — in-place update)
# ---------------------------------------------------------------------------

proc replaceFile(path: string; data: openArray[byte]): bool =
  ## Write replacement bytes beside `path`, then rename the complete file.
  let tmp = path & ".uniimage-" & $getCurrentProcessId() & ".tmp"
  if fileExists(tmp): return false
  var f: File
  try:
    if not open(f, tmp, fmWrite): return false
    if data.len > 0 and f.writeBuffer(unsafeAddr data[0], data.len) != data.len:
      close(f)
      removeFile(tmp)
      return false
    close(f)
    moveFile(tmp, path)
    true
  except CatchableError:
    if f != nil: close(f)
    if fileExists(tmp):
      try: removeFile(tmp)
      except CatchableError: discard
    false

proc writeExifOrientation*(path: string; orientation: int): bool =
  ## Updates the EXIF Orientation tag in a JPEG file **in-place**.
  ## Returns ``true`` on success, ``false`` if the file is not a JPEG or the
  ## Orientation tag (0x0112) is absent.  Only modifies the 2-byte SHORT value;
  ## no structural rewrite of the IFD is performed.
  if orientation < 1 or orientation > 8: return false

  # Read full file
  let fileSize = try: getFileSize(path) except CatchableError: 0'i64
  if fileSize == 0: return false
  var data = newSeq[byte](fileSize)
  var f: File
  try:
    if not open(f, path, fmRead): return false
    if f.readBuffer(addr data[0], int(fileSize)) != int(fileSize):
      close(f)
      return false
    close(f)
  except CatchableError:
    if f != nil: close(f)
    return false

  if data.len < 2 or data[0] != 0xFF or data[1] != 0xD8: return false

  let blockInfo = findExifAPP1(data)
  if blockInfo.offset <= 0: return false

  let tiffOffset = blockInfo.offset
  let endianChar = char(data[tiffOffset])
  let endian = if endianChar == 'I': LittleEndian else: BigEndian
  let firstIfdOffset = int(readUint32(data, tiffOffset + 4, endian))

  var currentIfdOffset = firstIfdOffset
  var visited = initTable[int, bool]()

  while currentIfdOffset != 0 and currentIfdOffset < blockInfo.length:
    if visited.hasKey(currentIfdOffset): break
    visited[currentIfdOffset] = true
    let ifdAbs = tiffOffset + currentIfdOffset
    if ifdAbs + 2 > data.len: break
    let numTags = int(readUint16(data, ifdAbs, endian))
    var tagOffset = ifdAbs + 2
    for i in 0 .. numTags - 1:
      if tagOffset + 12 > data.len: break
      let tagId = readUint16(data, tagOffset, endian)
      if tagId == 0x0112'u16:
        let tagType = readUint16(data, tagOffset + 2, endian)
        if tagType != 3: return false # must be SHORT
        # Orientation is always count=1, totalSize=2 <= 4, so value lives in the
        # 4-byte offset field.  We patch the first two bytes of that field.
        writeUint16(data, tagOffset + 8, uint16(orientation), endian)
        return replaceFile(path, data)
      tagOffset += 12
    if ifdAbs + 2 + numTags * 12 + 4 > data.len: break
    currentIfdOffset = int(readUint32(data, ifdAbs + 2 + numTags * 12, endian))

  return false

# ---------------------------------------------------------------------------
# EXIF DateTimeOriginal write (JPEG only — in-place update)
# ---------------------------------------------------------------------------

proc writeExifDateTimeOriginal*(path: string; dateTime: string): bool =
  ## Updates the EXIF DateTimeOriginal (0x9003) and DateTime (0x0132) in a JPEG
  ## or TIFF file **in-place**.  ``dateTime`` is parsed and rewritten as
  ## ``"yyyy:MM:dd HH:mm:ss"`` ASCII (19 chars + null = 20 bytes).
  ## Returns ``true`` on success.
  ##
  ## In place is what makes this safe for a vendor RAW, which is a TIFF whose
  ## bulk is image strips: the replacement is the same twenty bytes as the
  ## value it overwrites, so no offset moves and nothing outside those bytes is
  ## rewritten. `writeExif` refuses such a file for the opposite reason -- it
  ## rebuilds the block and cannot carry the pixels across.
  let fileSize = try: getFileSize(path) except CatchableError: 0'i64
  if fileSize == 0: return false
  var data = newSeq[byte](fileSize)
  var f: File
  try:
    if not open(f, path, fmRead): return false
    if f.readBuffer(addr data[0], int(fileSize)) != int(fileSize):
      close(f)
      return false
    close(f)
  except CatchableError:
    if f != nil: close(f)
    return false

  if data.len < 8: return false

  # Where the TIFF block starts and how far it runs: the APP1 segment in a
  # JPEG, the file itself in a TIFF.
  var tiffOffset = -1
  var blockLength = 0
  if data[0] == 0xFF and data[1] == 0xD8:
    let blockInfo = findExifAPP1(data)
    if blockInfo.offset <= 0: return false
    tiffOffset = blockInfo.offset
    blockLength = blockInfo.length
  elif (data[0] == 0x49 and data[1] == 0x49 and data[2] == 0x2A and
        data[3] == 0x00) or
       (data[0] == 0x4D and data[1] == 0x4D and data[2] == 0x00 and
        data[3] == 0x2A):
    tiffOffset = 0
    blockLength = data.len
  else:
    return false
  let endianChar = char(data[tiffOffset])
  let endian = if endianChar == 'I': LittleEndian else: BigEndian
  let firstIfdOffset = int(readUint32(data, tiffOffset + 4, endian))

  let formatted = parseDateTime(dateTime).format("yyyy:MM:dd HH:mm:ss")

  proc patchDateTag(tagOffset: int): bool =
    let tagType = readUint16(data, tagOffset + 2, endian)
    if tagType != 2: return false
    let count = int(readUint32(data, tagOffset + 4, endian))
    if count < 10: return false
    if count <= 4:
      for i in 0..<count:
        data[tagOffset + 8 + i] = 0
      let limit = min(formatted.len, count)
      for i in 0..<limit:
        data[tagOffset + 8 + i] = byte(formatted[i])
    else:
      let valOffset = int(readUint32(data, tagOffset + 8, endian))
      let dataOffset = tiffOffset + valOffset
      if dataOffset + count > data.len: return false
      for i in 0..<count: data[dataOffset + i] = 0
      let limit = min(formatted.len, count)
      for i in 0..<limit:
        data[dataOffset + i] = byte(formatted[i])
    return true

  var exifIfdOffset = -1
  var dateTimeTagOffset = -1
  var dateTimeOriginalTagOffset = -1

  # Every copy, not the first: a RAW carries DateTimeOriginal in IFD0 as well
  # as in the Exif IFD, and patching one of the two would leave the file
  # disagreeing with itself about when the picture was taken.
  var dateTagOffsets: seq[int]
  var exifIfdOffsets: seq[int]

  proc collect(ifdAbsolute: int) =
    if ifdAbsolute + 2 > data.len: return
    let count = int(readUint16(data, ifdAbsolute, endian))
    var tagOffset = ifdAbsolute + 2
    for _ in 0 ..< count:
      if tagOffset + 12 > data.len: break
      case readUint16(data, tagOffset, endian)
      of 0x8769'u16:
        exifIfdOffsets.add tiffOffset + int(readUint32(data, tagOffset + 8, endian))
      of 0x9003'u16, 0x0132'u16, 0x9004'u16:
        dateTagOffsets.add tagOffset
      else: discard
      tagOffset += 12

  var currentIfdOffset = firstIfdOffset
  var visited = initTable[int, bool]()
  while currentIfdOffset != 0 and currentIfdOffset < blockLength:
    if visited.hasKey(currentIfdOffset): break
    visited[currentIfdOffset] = true
    let ifdAbs = tiffOffset + currentIfdOffset
    if ifdAbs + 2 > data.len: break
    collect(ifdAbs)
    let numTags = int(readUint16(data, ifdAbs, endian))
    if ifdAbs + 2 + numTags * 12 + 4 > data.len: break
    currentIfdOffset = int(readUint32(data, ifdAbs + 2 + numTags * 12, endian))

  for exifAbs in exifIfdOffsets:
    collect(exifAbs)

  var patched = false
  for tagOffset in dateTagOffsets:
    if patchDateTag(tagOffset): patched = true


  if not patched: return false

  replaceFile(path, data)

# ---------------------------------------------------------------------------
# JSON view (machine-readable output, exiftool-style integration path)
# ---------------------------------------------------------------------------

proc metaToJson*(m: Metadata): string =
  ## Render parsed metadata as pretty-printed JSON. Tag values are kept as
  ## strings (the same readable form `readMetadata` produces); GPS is surfaced as
  ## numbers under "gps". Escaping is handled by `std/json`.
  var o = newJObject()
  o["isValid"] = %m.isValid
  o["orientation"] = %m.orientation
  if m.cameraModel.len > 0: o["camera"] = %m.cameraModel
  if m.software.len > 0: o["software"] = %m.software
  if m.gpsLatitudeRef in {'N', 'S'} and m.gpsLongitudeRef in {'E', 'W'}:
    o["gps"] = %*{
      "latitude": m.gpsLatitude,
      "longitude": m.gpsLongitude,
      "altitude": m.gpsAltitude
    }
  var tags = newJObject()
  for k, v in m.allTags: tags[k] = %v
  o["tags"] = tags
  pretty(o, 2)
