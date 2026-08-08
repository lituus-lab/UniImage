# SPDX-License-Identifier: Apache-2.0

## makernotes — best-effort decoder for proprietary MakerNote blobs.
##
## Currently: Apple (iPhone/iPad). The Apple MakerNote is a standard TIFF IFD
## wrapped in a header: ASCII "Apple iOS\0\0", a 2-byte version, the byte-order
## marker "MM" (big-endian), then the IFD at offset 14. All internal value
## offsets are relative to the start of the blob, so the existing TIFF IFD reader
## is reused with tiffHeaderOffset = 0.
##
## Tag identities were verified against exiftool on a real iPhone 16 Pro HEIC.
## Unknown tags are surfaced as "Apple:0xNNNN" so nothing identifying is hidden
## (notably UUID-shaped values, useful for a privacy audit).

import ./tiff
import ./endian
import std/[tables, strutils, math]

const AppleMakerTags = {
  0x0001'u16: "MakerNoteVersion",
  0x0004'u16: "AEStable",
  0x0005'u16: "AETarget",
  0x0006'u16: "AEAverage",
  0x0007'u16: "AFStable",
  0x0008'u16: "AccelerationVector",
  0x000a'u16: "HDRImageType",
  0x000c'u16: "FocusDistanceRange",
  0x0014'u16: "ImageCaptureType",
  0x001f'u16: "PhotosAppFeatureFlags",
  0x0021'u16: "HDRHeadroom",
  0x0023'u16: "AFPerformance",
  0x0027'u16: "SignalToNoiseRatio",
  0x002b'u16: "PhotoIdentifier",
  0x002d'u16: "ColorTemperature",
  0x002e'u16: "CameraType",
  0x002f'u16: "FocusPosition",
  0x0030'u16: "HDRGain",
  0x0038'u16: "AFMeasuredDepth",
  0x003d'u16: "AFConfidence",
}.toTable

const AppleHeader = "Apple iOS"

proc getImageCaptureType(v: string): string =
  case v
  of "1": "ProRAW"
  of "2": "Portrait"
  of "10": "Photo"
  of "12": "Scene"
  else: v

proc getAppleCameraType(v: string): string =
  case v
  of "0": "Back Wide Angle"
  of "1": "Back Normal"
  of "6": "Front"
  else: v

proc toDecimals(s: string, decimals = 4): string =
  ## "a/b c/d" -> "x.xxxx y.yyyy" (trailing zeros trimmed). Leaves plain ints.
  var outp: seq[string]
  for tok in s.split(' '):
    let t = tok.strip()
    if t.len == 0: continue
    let slash = t.find('/')
    if slash < 0:
      outp.add t
      continue
    let num = try: t[0 ..< slash].parseFloat() except CatchableError: 0.0
    let den = try: t[slash+1 ..< t.len].parseFloat() except CatchableError: 1.0
    var d = if den == 0: "0" else: formatFloat(num / den, ffDecimal, decimals)
    if '.' in d:
      while d.len > 0 and d[^1] == '0': d.setLen(d.len - 1)
      if d.len > 0 and d[^1] == '.': d.setLen(d.len - 1)
    outp.add d
  outp.join(" ")

proc isAppleMakerNote*(raw: openArray[byte]): bool =
  if raw.len < 16: return false
  for i, c in AppleHeader:
    if raw[i] != byte(c): return false
  true

proc parseAppleMakerNote*(raw: seq[byte]): Table[string, string] =
  ## Returns a flat table keyed by "Apple:<name>" (or "Apple:0xNNNN" for tags we
  ## do not name). Returns an empty table if the blob is not a recognised Apple
  ## MakerNote.
  result = initTable[string, string]()
  if not isAppleMakerNote(raw): return
  # IFD starts at offset 14; value offsets are blob-relative (base 0).
  let ifd = readIFD(raw, 14, 0, BigEndian)
  for id, tag in ifd.tags:
    let named = AppleMakerTags.hasKey(id)
    # Skip unnamed binary blobs (acceleration matrix, embedded bplists): they are
    # noisy hex dumps with no audit value. Named tags are always surfaced.
    if not named and (tag.tagType == ttUndefined or
        (tag.tagType in {ttByte, ttSByte} and tag.count > 8)):
      continue
    var v = tag.toString()
    let name = if named: AppleMakerTags[id] else: "0x" & id.toHex(4)
    case name
    of "ImageCaptureType": v = getImageCaptureType(v)
    of "CameraType": v = getAppleCameraType(v)
    of "AccelerationVector", "FocusDistanceRange", "HDRHeadroom",
       "SignalToNoiseRatio", "HDRGain": v = toDecimals(v)
    else: discard
    result["Apple:" & name] = v

# --- Canon -----------------------------------------------------------------
#
# The Canon MakerNote is a standard TIFF IFD with NO wrapper header. Crucially,
# its entry value offsets are relative to the *original* TIFF header (the same
# base as the surrounding EXIF), not to the start of the MakerNote — so it must
# be parsed from the full buffer with that base.

const CanonTags = {
  0x0006'u16: "ImageType",
  0x0007'u16: "FirmwareVersion",
  0x0008'u16: "FileNumber",
  0x0009'u16: "OwnerName",
  0x000c'u16: "SerialNumber",
  0x0010'u16: "CanonModelID",
  0x0095'u16: "LensModel",
  0x0096'u16: "InternalSerialNumber",
}.toTable

# Canon CameraSettings (tag 0x0001) and ShotInfo (tag 0x0004) are int16 arrays
# where element[0] is the byte count and exiftool tag id N == array index N. The
# index→field layout is a single documented exiftool table, stable across models,
# so a curated subset of pure enums (verified byte-exact on a real EOS 300D) is
# safe. Value-conversion fields (APEX apertures, focal lengths, EV, distances,
# ISO) and unmapped/"n/a" sentinels are deliberately skipped — emit nothing for
# an unmapped value (a wrong reading is worse than an absent tag).
const
  CanonQuality = {1: "Economy", 2: "Normal", 3: "Fine", 4: "RAW",
                  5: "Superfine"}.toTable
  CanonFlashMode = {0: "Off", 1: "Auto", 2: "On", 3: "Red-eye reduction",
                    4: "Slow-sync", 5: "Red-eye reduction (Auto)",
                    6: "Red-eye reduction (On)", 16: "External flash"}.toTable
  CanonContinuousDrive = {0: "Single", 1: "Continuous"}.toTable
  CanonFocusMode = {0: "One-shot AF", 1: "AI Servo AF", 2: "AI Focus AF",
                    3: "Manual Focus (3)", 6: "Manual Focus (6)"}.toTable
  CanonRecordMode = {1: "JPEG", 2: "CRW+THM", 3: "AVI+THM", 4: "TIF",
                     5: "TIF+JPEG", 6: "CR2", 7: "CR2+JPEG", 9: "MOV",
                     10: "MP4"}.toTable
  CanonImageSizeMap = {0: "Large", 1: "Medium", 2: "Small"}.toTable
  CanonEasyMode = {0: "Full auto", 1: "Manual"}.toTable
  CanonMeteringMode = {0: "Default", 1: "Spot", 2: "Average", 3: "Evaluative",
                       4: "Partial", 5: "Center-weighted average"}.toTable
  CanonExposureMode = {0: "Easy", 1: "Program AE",
                       2: "Shutter speed priority AE",
                       3: "Aperture-priority AE",
                       4: "Manual", 5: "Depth-of-field AE", 6: "M-Dep",
                       7: "Bulb", 8: "Flexible-priority AE"}.toTable
  CanonWhiteBalance = {0: "Auto", 1: "Daylight", 2: "Cloudy", 3: "Tungsten",
                       4: "Fluorescent", 5: "Flash", 6: "Custom",
                       7: "Black & White", 8: "Shade"}.toTable
  CanonSlowShutter = {0: "Off", 1: "Night Scene", 2: "On", 3: "None"}.toTable
  CanonAEB = {0: "Off", 1: "On (shot 1)", 2: "On (shot 2)",
      3: "On (shot 3)"}.toTable
  CanonControlMode = {1: "Camera Local Control",
                      3: "Computer Remote Control"}.toTable
  CanonCameraType = {248: "EOS High-end", 250: "Compact", 252: "EOS Mid-range",
                     255: "DV Camera"}.toTable
  CanonAutoRotate = {0: "None", 1: "Rotate 90 CW", 2: "Rotate 180",
                     3: "Rotate 270 CW"}.toTable

proc canonArr(tag: Tag; idx: int): int =
  ## Signed int16 at array index `idx`, or `int.low` if out of range.
  if idx < 0 or (idx + 1) * 2 > tag.rawBytes.len: return int.low
  int(cast[int16](readUint16(tag.rawBytes, idx * 2, tag.endian)))

proc parseCanonMakerNote*(data: openArray[byte]; mnOffset, base: int;
                          endian: TiffEndianness): Table[string, string] =
  ## Decode the Canon MakerNote IFD at absolute `mnOffset`, resolving value
  ## offsets against the TIFF `base`. Curated top-level scalars plus a safe subset
  ## of the CameraSettings/ShotInfo int16 arrays (pure documented enums only).
  result = initTable[string, string]()
  if mnOffset < 0 or mnOffset + 2 > data.len: return
  let ifd = readIFD(data, mnOffset, base, endian)
  for id, tag in ifd.tags:
    if not CanonTags.hasKey(id): continue
    var v = tag.toString()
    if v.len == 0: continue
    case id
    of 0x0008'u16: # FileNumber: "DDD-NNNN" (exiftool form)
      let n = try: parseBiggestInt(v) except CatchableError: 0'i64
      v = $(n div 10000) & "-" & align($(n mod 10000), 4, '0')
    of 0x000c'u16: # SerialNumber: 10-digit zero-padded
      let n = try: parseBiggestInt(v) except CatchableError: 0'i64
      v = align($n, 10, '0')
    of 0x0010'u16: # CanonModelID: raw ID as hex (exiftool
      let n = try: parseBiggestUInt(v) except CatchableError: 0'u64 # maps it to a name)
      v = "0x" & toHex(n, 8).toLowerAscii()
    else: discard
    result["Canon:" & CanonTags[id]] = v

  template enumField(arr: Tag; idx: int; m: Table[int, string]; name: string) =
    let val = canonArr(arr, idx)
    if m.hasKey(val): result["Canon:" & name] = m[val]

  # CameraSettings (0x0001): curated pure enums.
  if ifd.tags.hasKey(0x0001'u16) and int(ifd.tags[0x0001'u16].tagType) == 3:
    let cs = ifd.tags[0x0001'u16]
    enumField(cs, 3, CanonQuality, "Quality")
    enumField(cs, 4, CanonFlashMode, "CanonFlashMode")
    enumField(cs, 5, CanonContinuousDrive, "ContinuousDrive")
    enumField(cs, 7, CanonFocusMode, "FocusMode")
    enumField(cs, 9, CanonRecordMode, "RecordMode")
    enumField(cs, 10, CanonImageSizeMap, "CanonImageSize")
    enumField(cs, 11, CanonEasyMode, "EasyMode")
    enumField(cs, 17, CanonMeteringMode, "MeteringMode")
    enumField(cs, 20, CanonExposureMode, "CanonExposureMode")

  # ShotInfo (0x0004): curated pure enums.
  if ifd.tags.hasKey(0x0004'u16) and int(ifd.tags[0x0004'u16].tagType) == 3:
    let si = ifd.tags[0x0004'u16]
    enumField(si, 7, CanonWhiteBalance, "WhiteBalance")
    enumField(si, 8, CanonSlowShutter, "SlowShutter")
    enumField(si, 16, CanonAEB, "AutoExposureBracketing")
    enumField(si, 18, CanonControlMode, "ControlMode")
    enumField(si, 26, CanonCameraType, "CameraType")
    enumField(si, 27, CanonAutoRotate, "AutoRotate")

# --- Nikon -----------------------------------------------------------------
#
# Three on-disk layouts:
#   Type 2 — a bare IFD, offsets relative to the outer TIFF base (like Canon).
#   Type 1 — "Nikon\0\x01\x00" header, then an IFD at offset 8.
#   Type 3 — "Nikon\0\x02..\0\0" header, then its OWN embedded TIFF header at
#            offset 10; the IFD offsets are relative to that header.
# Validated against a real Type 2 sample (Coolpix); Type 1/3 base maths follow
# the documented layout (the curated ASCII tags below share IDs across types).

const NikonTags = {
  0x0003'u16: "ColorMode",
  0x0004'u16: "Quality",
  0x0005'u16: "WhiteBalance",
  0x0006'u16: "Sharpness",
  0x0007'u16: "FocusMode",
  0x000f'u16: "ISOSelection",
  0x0080'u16: "ImageAdjustment",
  0x0082'u16: "AuxiliaryLens",
  0x0084'u16: "Lens",
}.toTable

proc parseNikonMakerNote*(data: openArray[byte]; mnOffset, base: int;
                          endian: TiffEndianness): Table[string, string] =
  result = initTable[string, string]()
  if mnOffset < 0 or mnOffset + 2 > data.len: return
  var ifdAt = mnOffset # absolute position of the IFD
  var nbase = base # base for resolving the IFD's value offsets
  var en = endian
  const hdr = "Nikon\0"
  var hasHdr = mnOffset + hdr.len <= data.len
  if hasHdr:
    for i in 0 ..< hdr.len:
      if data[mnOffset + i] != byte(hdr[i]): hasHdr = false; break
  if hasHdr:
    # Type 3 carries its own TIFF header at +10 (II/MM); Type 1 does not.
    if mnOffset + 12 <= data.len and
       (char(data[mnOffset + 10]) == 'I' or char(data[mnOffset + 10]) == 'M'):
      nbase = mnOffset + 10 # Type 3: offsets are header-relative
      en = if char(data[nbase]) == 'I': LittleEndian else: BigEndian
      ifdAt = nbase + int(readUint32(data, nbase + 4, en))
    else:
      ifdAt = mnOffset + 8 # Type 1
      nbase = mnOffset
  if ifdAt < 0 or ifdAt + 2 > data.len: return
  let ifd = readIFD(data, ifdAt, nbase, en)
  for id, tag in ifd.tags:
    if not NikonTags.hasKey(id): continue
    var v = tag.toString().strip()
    if v.len == 0: continue
    # exiftool presents these all-uppercase enum strings in title case
    # (AUTO -> Auto); acronyms like "AF-C" (a hyphen/non-letter) are left as-is.
    if v.allCharsInSet({'A'..'Z'}):
      v = $v[0] & v[1..^1].toLowerAscii()
    result["Nikon:" & NikonTags[id]] = v

# --- Panasonic -------------------------------------------------------------
#
# Header "Panasonic\0\0\0" (12 bytes) then an IFD; value offsets are relative to
# the outer TIFF base. Useful tags are mostly numeric enums (exiftool maps them);
# we map only the well-documented, stable values and emit nothing for the rest
# (an unmapped guess is worse than an absent tag).

const
  PanasonicQuality = {1: "TIFF", 2: "High", 3: "Normal", 6: "Very High",
                      7: "RAW", 9: "Motion Picture"}.toTable
  PanasonicWB = {1: "Auto", 2: "Daylight", 3: "Cloudy", 4: "Incandescent",
                 5: "Manual", 8: "Flash", 10: "Black & White", 11: "Manual",
                 12: "Shade"}.toTable
  PanasonicFocus = {1: "Auto", 2: "Manual", 4: "Auto, Focus button",
                    5: "Auto, Continuous"}.toTable
  PanasonicMacro = {1: "On", 2: "Off", 0x101: "Tele-macro",
                    0x201: "Macro Zoom"}.toTable
  PanasonicShooting = {1: "Normal", 2: "Portrait", 3: "Scenery", 4: "Sports",
                       5: "Night Portrait", 6: "Program",
                       7: "Aperture Priority",
                       8: "Shutter Priority", 9: "Macro", 10: "Spot",
                       11: "Manual", 12: "Movie Preview", 13: "Panning"}.toTable
  PanasonicAudio = {1: "Yes", 2: "No", 3: "Stereo"}.toTable
  PanasonicColorEffect = {1: "Off", 2: "Warm", 3: "Cool", 4: "Black & White",
                          5: "Sepia"}.toTable
  PanasonicBurstMode = {0: "Off", 1: "On", 2: "Infinite",
                        4: "Unlimited"}.toTable
  PanasonicContrastMode = {0: "Normal", 1: "Low", 2: "High"}.toTable
  PanasonicNoiseReduction = {0: "Standard", 1: "Low (-1)", 2: "High (+1)",
                             3: "Lowest (-2)", 4: "Highest (+2)"}.toTable
  PanasonicSelfTimer = {1: "Off", 2: "10 s", 3: "2 s"}.toTable
  PanasonicOIS = {2: "On, Mode 1", 3: "Off", 4: "On, Mode 2", 5: "Panning",
                  6: "On, Mode 3"}.toTable

proc panaSerial(s: string): string =
  ## "S000407190102" -> "(S00) 2004:07:19 no. 0102" (exiftool form). Returns "" if
  ## the value does not match the expected fixed layout (so nothing is emitted for
  ## an unexpected serial shape rather than a wrong reformat).
  if s.len < 13: return ""
  for i in 3 ..< 9:
    if s[i] notin {'0'..'9'}: return ""
  "(" & s[0..2] & ") 20" & s[3..4] & ":" & s[5..6] & ":" & s[7..8] &
    " no. " & s[9..^1]

proc panaPowerTime(centisec: int): string =
  ## TimeSincePowerOn: hundredths of a second -> "HH:MM:SS.cc" (exiftool form).
  if centisec < 0: return ""
  let cs = centisec mod 100
  let total = centisec div 100
  result = align($(total div 3600), 2, '0') & ":" &
           align($((total div 60) mod 60), 2, '0') & ":" &
           align($(total mod 60), 2, '0') & "." & align($cs, 2, '0')

proc parsePanasonicMakerNote*(data: openArray[byte]; mnOffset, base: int;
                              endian: TiffEndianness): Table[string, string] =
  result = initTable[string, string]()
  const hdr = "Panasonic"
  if mnOffset < 0 or mnOffset + 12 > data.len: return
  for i in 0 ..< hdr.len:
    if data[mnOffset + i] != byte(hdr[i]): return
  let ifd = readIFD(data, mnOffset + 12, base, endian) # IFD after the 12-byte header
  proc num(s: string): int = (try: parseInt(s.split(' ')[
      0]) except CatchableError: -1)
  for id, tag in ifd.tags:
    case id
    of 0x0001'u16:
      let n = num(tag.toString())
      if PanasonicQuality.hasKey(n): result[
          "Panasonic:ImageQuality"] = PanasonicQuality[n]
    of 0x0002'u16: # FirmwareVersion: 4 bytes joined by "."
      if tag.rawBytes.len >= 4:
        result["Panasonic:FirmwareVersion"] =
          $tag.rawBytes[0] & "." & $tag.rawBytes[1] & "." &
          $tag.rawBytes[2] & "." & $tag.rawBytes[3]
    of 0x0003'u16:
      let n = num(tag.toString())
      if PanasonicWB.hasKey(n): result["Panasonic:WhiteBalance"] = PanasonicWB[n]
    of 0x0007'u16:
      let n = num(tag.toString())
      if PanasonicFocus.hasKey(n): result[
          "Panasonic:FocusMode"] = PanasonicFocus[n]
    of 0x0026'u16: # PanasonicExifVersion: ASCII "0100"
      let v = tag.toString().strip()
      if v.len > 0: result["Panasonic:PanasonicExifVersion"] = v
    of 0x001c'u16:
      if PanasonicMacro.hasKey(num(tag.toString())): result[
          "Panasonic:MacroMode"] = PanasonicMacro[num(tag.toString())]
    of 0x001f'u16:
      if PanasonicShooting.hasKey(num(tag.toString())): result[
          "Panasonic:ShootingMode"] = PanasonicShooting[num(tag.toString())]
    of 0x0020'u16:
      if PanasonicAudio.hasKey(num(tag.toString())): result[
          "Panasonic:Audio"] = PanasonicAudio[num(tag.toString())]
    of 0x0025'u16: # InternalSerialNumber (reformatted, guarded)
      let v = panaSerial(tag.toString().strip())
      if v.len > 0: result["Panasonic:InternalSerialNumber"] = v
    of 0x0028'u16:
      if PanasonicColorEffect.hasKey(num(tag.toString())): result[
          "Panasonic:ColorEffect"] = PanasonicColorEffect[num(tag.toString())]
    of 0x002a'u16:
      if PanasonicBurstMode.hasKey(num(tag.toString())): result[
          "Panasonic:BurstMode"] = PanasonicBurstMode[num(tag.toString())]
    of 0x002b'u16: # SequenceNumber: raw integer
      let n = num(tag.toString())
      if n >= 0: result["Panasonic:SequenceNumber"] = $n
    of 0x002c'u16:
      if PanasonicContrastMode.hasKey(num(tag.toString())): result[
          "Panasonic:ContrastMode"] = PanasonicContrastMode[num(tag.toString())]
    of 0x002d'u16:
      if PanasonicNoiseReduction.hasKey(num(tag.toString())): result[
          "Panasonic:NoiseReduction"] = PanasonicNoiseReduction[num(
          tag.toString())]
    of 0x002e'u16:
      if PanasonicSelfTimer.hasKey(num(tag.toString())): result[
          "Panasonic:SelfTimer"] = PanasonicSelfTimer[num(tag.toString())]
    of 0x001a'u16:
      if PanasonicOIS.hasKey(num(tag.toString())): result[
          "Panasonic:ImageStabilization"] = PanasonicOIS[num(tag.toString())]
    of 0x0029'u16: # TimeSincePowerOn: hundredths of a second
      let v = panaPowerTime(num(tag.toString()))
      if v.len > 0: result["Panasonic:TimeSincePowerOn"] = v
    else: discard

# --- FujiFilm --------------------------------------------------------------
#
# Header "FUJIFILM" (8 bytes) then a 4-byte little-endian offset to the IFD,
# RELATIVE TO THE MAKERNOTE START (not the outer TIFF base); the whole block is
# little-endian regardless of the outer byte order.

const
  FujiWB = {0: "Auto", 256: "Daylight", 512: "Cloudy",
            768: "Daylight Fluorescent", 769: "Day White Fluorescent",
            770: "White Fluorescent", 1024: "Incandescent",
            3840: "Custom"}.toTable
  FujiOnOff = {0: "Off", 1: "On"}.toTable
  FujiFocus = {0: "Auto", 1: "Manual"}.toTable
  FujiFlashMode = {0: "Auto", 1: "On", 2: "Off", 3: "Red-eye reduction",
                   4: "External"}.toTable
  FujiPictureMode = {0: "Auto", 1: "Portrait", 2: "Landscape", 4: "Sports",
                     5: "Night", 6: "Program AE", 256: "Aperture-priority AE",
                     512: "Shutter speed priority AE", 768: "Manual"}.toTable
  FujiAutoBracketing = {0: "Off", 1: "On", 2: "No flash & flash"}.toTable
  FujiBlurWarning = {0: "None", 1: "Blur Warning"}.toTable
  FujiFocusWarning = {0: "Good", 1: "Out of focus"}.toTable
  FujiExposureWarning = {0: "Good", 1: "Bad exposure"}.toTable

proc parseFujiMakerNote*(data: openArray[byte]; mnOffset: int): Table[string, string] =
  result = initTable[string, string]()
  const hdr = "FUJIFILM"
  if mnOffset < 0 or mnOffset + 12 > data.len: return
  for i in 0 ..< hdr.len:
    if data[mnOffset + i] != byte(hdr[i]): return
  let ifdOff = mnOffset + int(readUint32(data, mnOffset + 8, LittleEndian))
  if ifdOff < 0 or ifdOff + 2 > data.len: return
  let ifd = readIFD(data, ifdOff, mnOffset, LittleEndian) # base = makernote start
  proc num(s: string): int = (try: parseInt(s.split(' ')[
      0]) except CatchableError: -1)
  for id, tag in ifd.tags:
    case id
    of 0x0000'u16: # Version (ASCII, e.g. "0130")
      let v = tag.toString().strip()
      if v.len > 0: result["FujiFilm:Version"] = v
    of 0x1000'u16: # Quality (ASCII, kept verbatim e.g. "NORMAL")
      let v = tag.toString().strip()
      if v.len > 0: result["FujiFilm:Quality"] = v
    of 0x1002'u16:
      if FujiWB.hasKey(num(tag.toString())): result[
          "FujiFilm:WhiteBalance"] = FujiWB[num(tag.toString())]
    of 0x1020'u16:
      if FujiOnOff.hasKey(num(tag.toString())): result[
          "FujiFilm:Macro"] = FujiOnOff[num(tag.toString())]
    of 0x1021'u16:
      if FujiFocus.hasKey(num(tag.toString())): result[
          "FujiFilm:FocusMode"] = FujiFocus[num(tag.toString())]
    of 0x1030'u16:
      if FujiOnOff.hasKey(num(tag.toString())): result[
          "FujiFilm:SlowSync"] = FujiOnOff[num(tag.toString())]
    of 0x1010'u16:
      if FujiFlashMode.hasKey(num(tag.toString())): result[
          "FujiFilm:FujiFlashMode"] = FujiFlashMode[num(tag.toString())]
    of 0x1031'u16:
      if FujiPictureMode.hasKey(num(tag.toString())): result[
          "FujiFilm:PictureMode"] = FujiPictureMode[num(tag.toString())]
    of 0x1100'u16:
      if FujiAutoBracketing.hasKey(num(tag.toString())): result[
          "FujiFilm:AutoBracketing"] = FujiAutoBracketing[num(tag.toString())]
    of 0x1300'u16:
      if FujiBlurWarning.hasKey(num(tag.toString())): result[
          "FujiFilm:BlurWarning"] = FujiBlurWarning[num(tag.toString())]
    of 0x1301'u16:
      if FujiFocusWarning.hasKey(num(tag.toString())): result[
          "FujiFilm:FocusWarning"] = FujiFocusWarning[num(tag.toString())]
    of 0x1302'u16:
      if FujiExposureWarning.hasKey(num(tag.toString())): result[
          "FujiFilm:ExposureWarning"] = FujiExposureWarning[num(tag.toString())]
    else: discard

# --- Pentax ----------------------------------------------------------------
#
# Modern Pentax DSLRs use the "AOC\0" maker note: 4-byte "AOC\0" tag, a 2-byte
# byte-order marker ("II"/"MM"), then a bare IFD at offset 6. Value offsets are
# relative to the OUTER TIFF base (verified on a real K10D: WhitePoint at an
# offset resolves correctly only against the TIFF base, like Canon). The IFD is
# read in the maker note's own byte order. Older "PENTAX \0" notes use a
# different layout and are not decoded here (fallback to a hex dump).
#
# Curated, deterministic top-level tags only. Sub-directory binary tables
# (CameraSettings, AEInfo, LensInfo, …) are deliberately not descended into:
# decoding their packed fields correctly is model-specific and a wrong field is
# worse than an absent tag.

const
  PentaxQuality = {0: "Good", 1: "Better", 2: "Best", 3: "TIFF", 4: "RAW",
                   5: "Premium"}.toTable
  PentaxMeteringMode = {0: "Multi-segment", 1: "Center-weighted average",
                        2: "Spot"}.toTable
  PentaxWhiteBalance = {0: "Auto", 1: "Daylight", 2: "Shade", 3: "Fluorescent",
                        4: "Tungsten", 5: "Manual", 6: "Daylight Fluorescent",
                        7: "Day White Fluorescent", 8: "White Fluorescent",
                        9: "Flash", 10: "Cloudy"}.toTable
  PentaxImageTone = {0: "Natural", 1: "Bright", 2: "Portrait", 3: "Landscape",
                     4: "Vibrant", 5: "Monochrome"}.toTable
  PentaxOnOff = {0: "Off", 1: "On"}.toTable
  PentaxSRResult = {0: "Not stabilized", 1: "Stabilized"}.toTable
  PentaxYesNo = {0: "No", 1: "Yes"}.toTable
  PentaxWorldTime = {0: "Hometown", 1: "Destination"}.toTable
  PentaxAFPoint = {6: "Center"}.toTable # verified K10D value; emit only mapped
  PentaxModelID = {0x12C1E: "K10D"}.toTable # exiftool %pentaxModelID (verified entry)
  PentaxRawDev = {1: "1 (K10D,K200D,K2000,K-m)"}.toTable
  # --- CameraSettings (0x0205) sub-block, from exiftool Pentax::CameraSettings ---
  PCSPictureMode2 = {0: "Scene Mode", 1: "Auto PICT", 2: "Program AE",
    3: "Green Mode", 4: "Shutter Speed Priority", 5: "Aperture Priority",
    6: "Program Tv Shift", 7: "Program Av Shift", 8: "Manual", 9: "Bulb",
    10: "Aperture Priority, Off-Auto-Aperture", 11: "Manual, Off-Auto-Aperture",
    12: "Bulb, Off-Auto-Aperture", 13: "Shutter & Aperture Priority AE",
    15: "Sensitivity Priority AE", 16: "Flash X-Sync Speed AE"}.toTable
  PCSProgramLine = {0: "Normal", 1: "Hi Speed", 2: "Depth", 3: "MTF"}.toTable
  PCSEVSteps = {0: "1/2 EV Steps", 1: "1/3 EV Steps"}.toTable
  PCSEDial = {0: "Tv or Av", 1: "P Shift"}.toTable
  PCSApertureRing = {0: "Prohibited", 1: "Permitted"}.toTable
  PCSFlashOptions = {0: "Normal", 1: "Red-eye reduction", 2: "Auto",
    3: "Auto, Red-eye reduction", 5: "Wireless (Master)",
    6: "Wireless (Control)",
    8: "Slow-sync", 9: "Slow-sync, Red-eye reduction",
    10: "Trailing-curtain Sync"}.toTable
  PCSFocusMode2 = {0: "Manual", 1: "AF-S", 2: "AF-C", 3: "AF-A"}.toTable
  PCSExpBracketStep = {3: "0.3", 4: "0.5", 5: "0.7", 8: "1.0", 11: "1.3",
    12: "1.5", 13: "1.7", 16: "2.0"}.toTable
  PCSWhiteBalanceSet = {0: "Auto", 1: "Daylight", 2: "Shade", 3: "Cloudy",
    4: "Daylight Fluorescent", 5: "Day White Fluorescent",
    6: "White Fluorescent",
    7: "Tungsten", 8: "Flash", 9: "Manual", 12: "Set Color Temperature 1",
    13: "Set Color Temperature 2", 14: "Set Color Temperature 3"}.toTable
  PCSRawJpg = {0x01: "JPEG (Best)", 0x04: "RAW (PEF, Best)",
    0x05: "RAW+JPEG (PEF, Best)", 0x08: "RAW (DNG, Best)",
    0x09: "RAW+JPEG (DNG, Best)", 0x21: "JPEG (Better)",
    0x24: "RAW (PEF, Better)",
    0x25: "RAW+JPEG (PEF, Better)", 0x28: "RAW (DNG, Better)",
    0x29: "RAW+JPEG (DNG, Better)", 0x41: "JPEG (Good)",
    0x44: "RAW (PEF, Good)",
    0x45: "RAW+JPEG (PEF, Good)", 0x48: "RAW (DNG, Good)",
    0x49: "RAW+JPEG (DNG, Good)"}.toTable
  PCSJpgPixels = {0: "10 MP", 1: "6 MP", 2: "2 MP"}.toTable
  PCSRotation = {0: "Horizontal (normal)", 1: "Rotate 180", 2: "Rotate 90 CW",
    3: "Rotate 270 CW"}.toTable
  PCSISOSetting = {0: "Manual", 1: "Auto"}.toTable
  PCSSensSteps = {0: "1 EV Steps", 1: "As EV Steps"}.toTable

proc pentaxEv(v: int): float =
  ## exiftool Pentax::PentaxEv: non-linear APEX step decode.
  var val = v.float
  if (v and 0x01) != 0:
    let sign = if v < 0: -1.0 else: 1.0
    let frac = (v * (if v < 0: -1 else: 1)) and 0x07
    if frac == 0x03: val += sign * (8.0 / 3.0 - frac.float)
    elif frac == 0x05: val += sign * (16.0 / 3.0 - frac.float)
  val / 8.0

proc bitmaskStr(v: int; zero: string; bits: openArray[(int, string)]): string =
  ## exiftool BITMASK: 0 -> `zero`; else join set-bit names. Unmapped bits -> "".
  if v == 0: return zero
  var parts: seq[string]
  for (b, name) in bits:
    if (v and (1 shl b)) != 0: parts.add name
  if parts.len == 0: "" else: parts.join(", ")

proc pexpTime(secs: float): string =
  ## exiftool PrintExposureTime: "1/x" for fast, else 1-decimal.
  if secs > 0 and secs < 0.25001: "1/" & $int(1.0 / secs + 0.5)
  else: formatFloat(secs, ffDecimal, 1)

proc trimFloat(v: float; decimals = 4): string =
  result = formatFloat(v, ffDecimal, decimals)
  if '.' in result:
    while result.len > 0 and result[^1] == '0': result.setLen(result.len - 1)
    if result.len > 0 and result[^1] == '.': result.setLen(result.len - 1)

const PCSAEProgramMode = {0: "M, P or TAv", 1: "Av, B or X", 2: "Tv",
  3: "Sv or Green Mode", 8: "Hi-speed Program",
  11: "Hi-speed Program (P-Shift)",
  16: "DOF Program", 19: "DOF Program (P-Shift)", 24: "MTF Program",
  27: "MTF Program (P-Shift)", 35: "Standard", 43: "Portrait", 51: "Landscape",
  59: "Macro", 67: "Sport", 75: "Night Scene Portrait", 83: "No Flash",
  91: "Night Scene", 99: "Surf & Snow", 104: "Night Snap", 107: "Text",
  115: "Sunset", 123: "Kids", 131: "Pet", 139: "Candlelight", 144: "SCN",
  147: "Museum", 160: "Program", 184: "Shallow DOF Program", 216: "HDR"}.toTable

proc addPentaxAEInfo(res: var Table[string, string]; ae: openArray[byte]) =
  ## Pentax AEInfo (0x0206), exiftool table offsets 0-12 (the fields exiftool
  ## surfaces for the 16-byte record; AEFlags at 7 is suppressed, as in exiftool).
  ## All conversions byte-exact per Pentax.pm. No index shift (record <= 20 bytes).
  if ae.len < 5: return
  res["Pentax:AEExposureTime"] = pexpTime(24.0 * pow(2.0, -(int(ae[0]) -
      32).float / 8.0))
  res["Pentax:AEAperture"] = formatFloat(pow(2.0, (int(ae[1]) - 68).float /
      16.0), ffDecimal, 1)
  res["Pentax:AE_ISO"] = $int(100.0 * pow(2.0, (int(ae[2]) - 32).float / 8.0) + 0.5)
  res["Pentax:AEXv"] = trimFloat((int(ae[3]) - 64).float / 8.0)
  res["Pentax:AEBXv"] = trimFloat(int(cast[int8](ae[4])).float / 8.0)
  if ae.len < 13: return
  res["Pentax:AEMinExposureTime"] = pexpTime(24.0 * pow(2.0, -(int(ae[5]) -
      32).float / 8.0))
  if PCSAEProgramMode.hasKey(int(ae[6])):
    res["Pentax:AEProgramMode"] = PCSAEProgramMode[int(ae[6])]
  res["Pentax:AEApertureSteps"] = (if int(ae[8]) == 255: "n/a" else: $int(ae[8]))
  res["Pentax:AEMaxAperture"] = formatFloat(pow(2.0, (int(ae[9]) - 68).float /
      16.0), ffDecimal, 1)
  res["Pentax:AEMaxAperture2"] = formatFloat(pow(2.0, (int(ae[10]) - 68).float /
      16.0), ffDecimal, 1)
  res["Pentax:AEMinAperture"] = strip(formatFloat(pow(2.0, (int(ae[11]) -
      68).float / 16.0), ffDecimal, 0), chars = {'.'})
  res["Pentax:AEMeteringMode"] = bitmaskStr(int(ae[12]), "Multi-segment",
    {4: "Center-weighted average", 5: "Spot"})

proc signedEv(ev: float): string =
  ## "+0.7" / "-0.3" / "0" (exiftool '$val ? sprintf("%+.1f",$val) : 0').
  if ev == 0: return "0"
  let s = formatFloat(ev, ffDecimal, 1)
  if s.len > 0 and s[0] != '-': "+" & s else: s

proc addPentaxCameraSettings(res: var Table[string, string]; cs: openArray[byte];
                             isK10D: bool) =
  ## Decode the Pentax CameraSettings (0x0205) binary block byte-exact per
  ## exiftool's table. K10D/GX10-specific fields are gated by model.
  template put(name, val: untyped) = (let vv = val; (if vv.len > 0: res[
      "Pentax:" & name] = vv))
  template enumAt(off: int; m: Table[int, string]; name: string) =
    if off < cs.len and m.hasKey(int(cs[off])): res["Pentax:" & name] = m[int(
        cs[off])]
  template maskEnum(off, mask, shift: int; m: Table[int, string];
      name: string) =
    if off < cs.len:
      let mvv = (int(cs[off]) and mask) shr shift
      if m.hasKey(mvv): res["Pentax:" & name] = m[mvv]
  if cs.len < 11: return
  enumAt(0, PCSPictureMode2, "PictureMode2")
  maskEnum(1, 0x03, 0, PCSProgramLine, "ProgramLine")
  maskEnum(1, 0x20, 5, PCSEVSteps, "EVSteps")
  maskEnum(1, 0x40, 6, PCSEDial, "E-DialInProgram")
  maskEnum(1, 0x80, 7, PCSApertureRing, "ApertureRingUse")
  maskEnum(2, 0xf0, 4, PCSFlashOptions, "FlashOptions")
  put("MeteringMode2", bitmaskStr(int(cs[2]) and 0x0f, "Multi-segment",
    {0: "Center-weighted average", 1: "Spot"}))
  put("AFPointMode", bitmaskStr((int(cs[3]) and 0xf0) shr 4, "Auto",
    {0: "Select", 1: "Fixed Center"}))
  maskEnum(3, 0x0f, 0, PCSFocusMode2, "FocusMode2")
  if cs.len >= 6: # AFPointSelected2: int16u at offset 4 (BE)
    put("AFPointSelected2", bitmaskStr((int(cs[4]) shl 8) or int(cs[5]), "Auto",
      {0: "Upper-left", 1: "Top", 2: "Upper-right", 3: "Left", 4: "Mid-left",
       5: "Center", 6: "Mid-right", 7: "Right", 8: "Lower-left", 9: "Bottom",
       10: "Lower-right"}))
  if cs.len >= 7: # ISOFloor (PentaxEv conversion)
    res["Pentax:ISOFloor"] = $int(100.0 * pow(2.0, pentaxEv(int(cs[6]) - 32)) + 0.5)
  put("DriveMode2", bitmaskStr(int(cs[7]), "Single-frame",
    {0: "Continuous", 1: "Continuous (Lo)", 2: "Self-timer (12 s)",
     3: "Self-timer (2 s)", 4: "Remote Control (3 s delay)",
     5: "Remote Control",
     6: "Exposure Bracket", 7: "Multiple Exposure"}))
  enumAt(8, PCSExpBracketStep, "ExposureBracketStepSize")
  if int(cs[9]) == 0: res["Pentax:BracketShotNumber"] = "n/a"
  maskEnum(10, 0xf0, 4, PCSWhiteBalanceSet, "WhiteBalanceSet")
  put("MultipleExposureSet", (if (int(cs[10]) and 0x0f) == 0: "Off"
    elif (int(cs[10]) and 0x0f) == 1: "On" else: ""))
  if not isK10D: return # remaining fields are K10D/GX10-specific
  if cs.len > 13 and PCSRawJpg.hasKey(int(cs[13])):
    res["Pentax:RawAndJpgRecording"] = PCSRawJpg[int(cs[13])]
  maskEnum(14, 0x03, 0, PCSJpgPixels, "JpgRecordedPixels")
  maskEnum(16, 0xf0, 4, PCSFlashOptions, "FlashOptions2")
  if cs.len > 16:
    put("MeteringMode3", bitmaskStr(int(cs[16]) and 0x0f, "Multi-segment",
      {0: "Center-weighted average", 1: "Spot"}))
  if cs.len > 17:
    put("SRActive", (if (int(cs[17]) and 0x80) != 0: "Yes" else: "No"))
    maskEnum(17, 0x60, 5, PCSRotation, "Rotation")
    maskEnum(17, 0x04, 2, PCSISOSetting, "ISOSetting")
    maskEnum(17, 0x02, 1, PCSSensSteps, "SensitivitySteps")
  if cs.len > 18: # TvExposureTimeSetting (PentaxEv + 1/x)
    let secs = pow(2.0, -pentaxEv(int(cs[18]) - 68))
    res["Pentax:TvExposureTimeSetting"] =
      (if secs > 0 and secs < 0.25001: "1/" & $int(1.0 / secs + 0.5)
        else: formatFloat(secs, ffDecimal, 1))
  if cs.len > 19: # AvApertureSetting
    res["Pentax:AvApertureSetting"] =
      formatFloat(pow(2.0, pentaxEv(int(cs[19]) - 68) / 2.0), ffDecimal, 1)
  if cs.len > 20: # SvISOSetting
    res["Pentax:SvISOSetting"] = $int(100.0 * pow(2.0, pentaxEv(int(cs[20]) -
        32)) + 0.5)
  if cs.len > 21: # BaseExposureCompensation
    res["Pentax:BaseExposureCompensation"] = signedEv(pentaxEv(64 - int(cs[21])))

proc parsePentaxMakerNote*(data: openArray[byte]; mnOffset, base: int;
                           endian: TiffEndianness; model = ""): Table[string, string] =
  result = initTable[string, string]()
  const hdr = "AOC\0"
  if mnOffset < 0 or mnOffset + 6 > data.len: return
  for i in 0 ..< hdr.len:
    if data[mnOffset + i] != byte(hdr[i]): return # not the AOC format
  let pen = if char(data[mnOffset + 4]) == 'I': LittleEndian else: BigEndian
  let ifd = readIFD(data, mnOffset + 6, base, pen)       # base = outer TIFF base
  for id, tag in ifd.tags:
    case id
    of 0x0000'u16: # PentaxVersion: 4 bytes joined by "."
      if tag.rawBytes.len >= 4:
        result["Pentax:PentaxVersion"] =
          $tag.rawBytes[0] & "." & $tag.rawBytes[1] & "." &
          $tag.rawBytes[2] & "." & $tag.rawBytes[3]
    of 0x0001'u16: # PentaxModelType: raw integer
      let v = tag.toString().strip()
      if v.len > 0: result["Pentax:PentaxModelType"] = v
    of 0x0006'u16: # Date: 2-byte year (note byte order) + month + day
      if tag.rawBytes.len >= 4:
        let yr = int(readUint16(tag.rawBytes, 0, pen))
        result["Pentax:Date"] =
          align($yr, 4, '0') & ":" & align($int(tag.rawBytes[2]), 2, '0') &
          ":" & align($int(tag.rawBytes[3]), 2, '0')
    of 0x0007'u16: # Time: hour:minute:second
      if tag.rawBytes.len >= 3:
        result["Pentax:Time"] =
          align($int(tag.rawBytes[0]), 2, '0') & ":" &
          align($int(tag.rawBytes[1]), 2, '0') & ":" &
          align($int(tag.rawBytes[2]), 2, '0')
    of 0x0008'u16: # Quality (enum)
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxQuality.hasKey(n): result["Pentax:Quality"] = PentaxQuality[n]
    of 0x0017'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxMeteringMode.hasKey(n): result[
          "Pentax:MeteringMode"] = PentaxMeteringMode[n]
    of 0x0019'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxWhiteBalance.hasKey(n): result[
          "Pentax:WhiteBalance"] = PentaxWhiteBalance[n]
    of 0x0048'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxOnOff.hasKey(n): result["Pentax:AELock"] = PentaxOnOff[n]
    of 0x0049'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxOnOff.hasKey(n): result["Pentax:NoiseReduction"] = PentaxOnOff[n]
    of 0x004f'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxImageTone.hasKey(n): result[
          "Pentax:ImageTone"] = PentaxImageTone[n]
    of 0x005c'u16: # SRInfo: BYTE[0]=SRResult, BYTE[1]=ShakeReduction
      if tag.rawBytes.len >= 2:
        let r = int(tag.rawBytes[0]); let s = int(tag.rawBytes[1])
        if PentaxSRResult.hasKey(r): result["Pentax:SRResult"] = PentaxSRResult[r]
        if PentaxOnOff.hasKey(s): result["Pentax:ShakeReduction"] = PentaxOnOff[s]
    of 0x0002'u16: # PreviewImageSize: "WxH"
      let p = tag.toString().split(' ')
      if p.len == 2: result["Pentax:PreviewImageSize"] = p[0] & "x" & p[1]
    of 0x0003'u16: # PreviewImageLength: raw int
      let v = tag.toString().strip()
      if v.len > 0: result["Pentax:PreviewImageLength"] = v
    of 0x0005'u16: # PentaxModelID (documented id table)
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxModelID.hasKey(n): result[
          "Pentax:PentaxModelID"] = PentaxModelID[n]
    of 0x000e'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxAFPoint.hasKey(n): result[
          "Pentax:AFPointSelected"] = PentaxAFPoint[n]
    of 0x0022'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxWorldTime.hasKey(n): result[
          "Pentax:WorldTimeLocation"] = PentaxWorldTime[n]
    of 0x0025'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxYesNo.hasKey(n): result["Pentax:HometownDST"] = PentaxYesNo[n]
    of 0x0026'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxYesNo.hasKey(n): result["Pentax:DestinationDST"] = PentaxYesNo[n]
    of 0x003d'u16: # DataScaling: raw int
      let v = tag.toString().strip()
      if v.len > 0: result["Pentax:DataScaling"] = v
    of 0x003e'u16: # PreviewImageBorders: 4 bytes, decimal-joined
      if tag.rawBytes.len >= 4:
        result["Pentax:PreviewImageBorders"] =
          $int(tag.rawBytes[0]) & " " & $int(tag.rawBytes[1]) & " " &
          $int(tag.rawBytes[2]) & " " & $int(tag.rawBytes[3])
    of 0x0041'u16: # ImageEditCount: raw int
      let v = tag.toString().strip()
      if v.len > 0: result["Pentax:ImageEditCount"] = v
    of 0x0047'u16: # CameraTemperature: signed byte + " C"
      if tag.rawBytes.len >= 1:
        result["Pentax:CameraTemperature"] = $int(cast[int8](tag.rawBytes[0])) & " C"
    of 0x0062'u16:
      let n = try: parseInt(tag.toString().split(' ')[
          0]) except CatchableError: -1
      if PentaxRawDev.hasKey(n): result[
          "Pentax:RawDevelopmentProcess"] = PentaxRawDev[n]
    of 0x0205'u16: # CameraSettings binary sub-block
      addPentaxCameraSettings(result, tag.rawBytes,
        model.contains("K10D") or model.contains("GX10"))
    of 0x0206'u16: # AEInfo binary sub-block
      addPentaxAEInfo(result, tag.rawBytes)
    else: discard

# --- Olympus ---------------------------------------------------------------
#
# Type 1 (older C-series): header "OLYMP\0" (6 bytes) + a 2-byte field, then a
# bare IFD at offset 8. Value offsets are relative to the OUTER TIFF base and the
# IFD uses the outer byte order (verified on a real C2000Z: CameraID and the
# signed LensDistortionParams resolve correctly only against the TIFF base). The
# newer Type 2 ("OLYMPUS\0...II") note has a different base scheme and is not
# decoded here (fallback to a hex dump).
#
# Curated tags only: deterministic ASCII / documented enums / a clean rational.
# Binary sub-blocks (SpecialMode triplet, DataDump, the [pictureInfo]/[Camera Info]
# packed struct) are not decoded.

const
  OlympusQuality = {1: "SQ (Low)", 2: "HQ (Normal)", 3: "SHQ (Fine)",
                    4: "RAW"}.toTable
  OlympusMacro = {0: "Off", 1: "On", 2: "Super Macro"}.toTable
  OlympusOnOff = {0: "Off", 1: "On"}.toTable
  OlympusSpecialModeMode = {0: "Normal", 1: "Unknown", 2: "Fast",
                            3: "Panorama"}.toTable
  OlympusPanoramaDir = {0: "(none)", 1: "Left to right", 2: "Right to left",
                        3: "Bottom to top", 4: "Top to bottom"}.toTable
  # Olympus camera-type id -> model (exiftool %olympusCameraTypes). Verified
  # SR951->C2000Z on a real fixture; emit only mapped ids (no guessing).
  OlympusCameraType = {"SR951": "C2000Z"}.toTable

proc ratToDecimal(s: string): string =
  ## "num/den" -> trimmed decimal (e.g. "39/5" -> "7.8"). Returns "" if not a
  ## single rational. Deterministic: derived from the same integers exiftool uses.
  let slash = s.find('/')
  if slash <= 0 or ' ' in s: return ""
  let num = try: parseFloat(s[0 ..< slash]) except CatchableError: return ""
  let den = try: parseFloat(s[slash+1 .. ^1]) except CatchableError: return ""
  if den == 0: return ""
  var d = formatFloat(num / den, ffDecimal, 6)
  if '.' in d:
    while d.len > 0 and d[^1] == '0': d.setLen(d.len - 1)
    if d.len > 0 and d[^1] == '.': d.setLen(d.len - 1)
  d

proc parseOlympusMakerNote*(data: openArray[byte]; mnOffset, base: int;
                            endian: TiffEndianness): Table[string, string] =
  result = initTable[string, string]()
  const hdr = "OLYMP\0"
  if mnOffset < 0 or mnOffset + 8 > data.len: return
  for i in 0 ..< hdr.len:
    if data[mnOffset + i] != byte(hdr[i]): return # not the Type 1 format
  let ifd = readIFD(data, mnOffset + 8, base, endian) # base = outer TIFF base
  proc num(s: string): int = (try: parseInt(s.split(' ')[
      0]) except CatchableError: -1)
  for id, tag in ifd.tags:
    case id
    of 0x0201'u16:
      if OlympusQuality.hasKey(num(tag.toString())):
        result["Olympus:Quality"] = OlympusQuality[num(tag.toString())]
    of 0x0202'u16:
      if OlympusMacro.hasKey(num(tag.toString())):
        result["Olympus:Macro"] = OlympusMacro[num(tag.toString())]
    of 0x0203'u16:
      if OlympusOnOff.hasKey(num(tag.toString())):
        result["Olympus:BWMode"] = OlympusOnOff[num(tag.toString())]
    of 0x0205'u16: # FocalPlaneDiagonal: rational + " mm"
      let d = ratToDecimal(tag.toString())
      if d.len > 0: result["Olympus:FocalPlaneDiagonal"] = d & " mm"
    of 0x0209'u16: # CameraID: ASCII, verbatim
      let v = tag.toString().strip()
      if v.len > 0: result["Olympus:CameraID"] = v
    of 0x0200'u16: # SpecialMode: mode, Sequence: N, Panorama: dir
      let parts = tag.toString().split(' ')
      if parts.len >= 3:
        let mode = try: parseInt(parts[0]) except CatchableError: -1
        let pan = try: parseInt(parts[2]) except CatchableError: -1
        if OlympusSpecialModeMode.hasKey(mode) and OlympusPanoramaDir.hasKey(pan):
          result["Olympus:SpecialMode"] = OlympusSpecialModeMode[mode] &
            ", Sequence: " & parts[1] & ", Panorama: " & OlympusPanoramaDir[pan]
    of 0x0204'u16: # DigitalZoom: rational -> 1-decimal (exiftool form)
      if tag.rawBytes.len >= 8:
        let de = readUint32(tag.rawBytes, 4, tag.endian).float
        if de != 0:
          result["Olympus:DigitalZoom"] =
            formatFloat(readUint32(tag.rawBytes, 0, tag.endian).float / de,
                ffDecimal, 1)
    of 0x0206'u16: # LensDistortionParams: signed short array, verbatim
      let v = tag.toString().strip()
      if v.len > 0 and v[0] in {'-', '0'..'9'}: result[
          "Olympus:LensDistortionParams"] = v
    of 0x0207'u16: # CameraType: id -> model (documented table)
      let v = tag.toString().strip()
      if OlympusCameraType.hasKey(v): result[
          "Olympus:CameraType"] = OlympusCameraType[v]
    of 0x0208'u16: # PictureInfo: extract "Resolution=N"
      let s = tag.toString(); let idx = s.find("Resolution=")
      if idx >= 0:
        var n = ""
        var i = idx + len("Resolution=")
        while i < s.len and s[i] in {'0'..'9'}: n.add s[i]; inc i
        if n.len > 0: result["Olympus:Resolution"] = n
    else: discard

# --- Casio -----------------------------------------------------------------
#
# Type 1 (older QV/EX models): NO header — the maker note IS a bare IFD, in the
# outer TIFF byte order. All curated values are inline (≤4 bytes), so the base is
# irrelevant; we pass the outer TIFF base for correctness anyway. Verified on a
# real CASIO sample. The newer Type 2 note carries a "QVC\0\0\0" header and a
# different tag set / base scheme — not decoded here (fallback to a hex dump).
#
# Enum values are emitted only via documented, stable maps; an unmapped value
# emits nothing.

const
  CasioRecordingMode = {1: "Single Shutter", 2: "Panorama", 3: "Night Scene",
                        4: "Portrait", 5: "Landscape"}.toTable
  CasioQuality = {1: "Economy", 2: "Normal", 3: "Fine"}.toTable
  CasioFocusMode = {2: "Macro", 3: "Auto", 4: "Manual", 5: "Infinity",
                    7: "Sport AF"}.toTable
  CasioFlashMode = {1: "Auto", 2: "On", 3: "Off",
      4: "Red-eye Reduction"}.toTable
  CasioFlashIntensity = {11: "Weak", 13: "Normal", 15: "Strong"}.toTable
  CasioWhiteBalance = {1: "Auto", 2: "Tungsten", 3: "Daylight",
                       4: "Fluorescent", 5: "Shade", 129: "Manual"}.toTable
  CasioNormalLowHigh = {0: "Normal", 1: "Low", 2: "High"}.toTable
  CasioSharpness = {0: "Normal", 1: "Soft", 2: "Hard"}.toTable

proc parseCasioMakerNote*(data: openArray[byte]; mnOffset, base: int;
                          endian: TiffEndianness): Table[string, string] =
  result = initTable[string, string]()
  if mnOffset < 0 or mnOffset + 2 > data.len: return
  const qvc = "QVC\0" # Type 2 header — not decoded here
  if mnOffset + qvc.len <= data.len:
    var isType2 = true
    for i in 0 ..< qvc.len:
      if data[mnOffset + i] != byte(qvc[i]): isType2 = false; break
    if isType2: return
  let ifd = readIFD(data, mnOffset, base, endian)       # bare IFD, outer endian
  proc num(s: string): int = (try: parseInt(s.split(' ')[
      0]) except CatchableError: -1)
  for id, tag in ifd.tags:
    let n = num(tag.toString())
    case id
    of 0x0001'u16:
      if CasioRecordingMode.hasKey(n): result[
          "Casio:RecordingMode"] = CasioRecordingMode[n]
    of 0x0002'u16:
      if CasioQuality.hasKey(n): result["Casio:Quality"] = CasioQuality[n]
    of 0x0003'u16:
      if CasioFocusMode.hasKey(n): result["Casio:FocusMode"] = CasioFocusMode[n]
    of 0x0004'u16:
      if CasioFlashMode.hasKey(n): result["Casio:FlashMode"] = CasioFlashMode[n]
    of 0x0005'u16:
      if CasioFlashIntensity.hasKey(n): result[
          "Casio:FlashIntensity"] = CasioFlashIntensity[n]
    of 0x0006'u16: # ObjectDistance: millimetres -> "N.n m"
      if n >= 0:
        var d = formatFloat(n.float / 1000.0, ffDecimal, 3)
        if '.' in d:
          while d.len > 0 and d[^1] == '0': d.setLen(d.len - 1)
          if d.len > 0 and d[^1] == '.': d.setLen(d.len - 1)
        result["Casio:ObjectDistance"] = d & " m"
    of 0x0007'u16:
      if CasioWhiteBalance.hasKey(n): result[
          "Casio:WhiteBalance"] = CasioWhiteBalance[n]
    of 0x000a'u16:
      if n == 0x10000: result["Casio:DigitalZoom"] = "Off" # only the verified value
    of 0x000b'u16:
      if CasioSharpness.hasKey(n): result["Casio:Sharpness"] = CasioSharpness[n]
    of 0x000c'u16:
      if CasioNormalLowHigh.hasKey(n): result[
          "Casio:Contrast"] = CasioNormalLowHigh[n]
    of 0x000d'u16:
      if CasioNormalLowHigh.hasKey(n): result[
          "Casio:Saturation"] = CasioNormalLowHigh[n]
    else: discard

# --- Minolta ---------------------------------------------------------------
#
# No header — the maker note IS a bare IFD (outer byte order, value offsets
# relative to the outer TIFF base). Verified on a real DiMAGE 7i.
#
# The rich Minolta fields exiftool prints (FlashMode, WhiteBalance, MinoltaDate,
# MinoltaModelID, …) live in the packed "CameraSettings" (new) array, tag 0x0003:
# a big-endian int32 array where exiftool tag id N == array index N, decoded
# through one documented, stable table. As with the Canon arrays, a curated subset
# of pure enums (plus the deterministic packed Date/Time) is decoded and verified
# byte-exact on a real DiMAGE 7i. The OLD CameraSettings (tag 0x0001) uses a
# different table and is not decoded (no verifiable fixture); other binary blocks
# (0x0010/0x0020) and value-conversion fields are left alone — an unmapped value
# emits nothing (a wrong reading is worse than an absent tag).
#
# (Note: PreviewImageStart 0x0088 is deliberately omitted — exiftool reports it
# rebased by the maker-note offset, which is a fragile computed file position,
# not a stable metadata value.)

const
  MinoltaFlashMode = {0: "Fill flash", 1: "Red-eye reduction",
                      2: "Rear flash sync", 3: "Wireless", 4: "Off"}.toTable
  MinoltaWhiteBalance = {0: "Auto", 1: "Daylight", 2: "Cloudy", 3: "Tungsten",
                         5: "Custom", 7: "Fluorescent", 8: "Fluorescent 2",
                         11: "Custom 2", 12: "Custom 3"}.toTable
  MinoltaImageSize = {0: "Full", 1: "1600x1200", 2: "1280x960", 3: "640x480",
                      5: "2560x1920", 6: "2272x1704", 7: "2048x1536"}.toTable
  MinoltaQuality = {0: "Raw", 1: "Super Fine", 2: "Fine", 3: "Standard",
                    4: "Economy", 5: "Extra Fine"}.toTable
  MinoltaDriveMode = {0: "Single", 1: "Continuous", 2: "Self-timer",
                      4: "Bracketing", 5: "Interval", 6: "UHS continuous",
                      7: "HS continuous"}.toTable
  MinoltaOnOff = {0: "Off", 1: "On"}.toTable
  MinoltaDigitalZoom = {0: "Off", 1: "Electronic magnification",
      2: "2x"}.toTable
  MinoltaNoYes = {0: "No", 1: "Yes"}.toTable
  MinoltaSubjectProgram = {0: "None", 1: "Portrait", 2: "Text",
                           3: "Night portrait", 4: "Sports action",
                           5: "Landscape"}.toTable
  MinoltaModelID = {0: "DiMAGE 7/X/Z", 1: "DiMAGE 5", 2: "DiMAGE S304",
                    3: "DiMAGE S404", 4: "DiMAGE 7i", 5: "DiMAGE 7Hi",
                    6: "DiMAGE A1", 7: "DiMAGE A2/S414"}.toTable
  MinoltaIntervalMode = {0: "Still Image", 1: "Time-lapse Movie"}.toTable
  MinoltaFolderName = {0: "Standard Form", 1: "Data Form"}.toTable
  MinoltaColorMode = {0: "Natural color", 1: "Black & White", 2: "Vivid color",
                      3: "Solarization", 4: "Adobe RGB"}.toTable
  MinoltaInternalFlash = {0: "No", 1: "Fired"}.toTable
  MinoltaWideFocusZone = {0: "No zone",
                          1: "Center zone (horizontal orientation)",
                          2: "Center zone (vertical orientation)",
                          3: "Left zone", 4: "Right zone"}.toTable
  MinoltaFocusMode = {0: "AF", 1: "MF"}.toTable
  MinoltaFocusArea = {0: "Wide Focus (normal)", 1: "Spot Focus"}.toTable
  MinoltaDECPosition = {0: "Exposure", 1: "Contrast", 2: "Saturation",
                        3: "Filter"}.toTable

proc minoltaArr(tag: Tag; idx: int): int =
  ## Unsigned int32 at array index `idx`, or `int.low` if out of range.
  if idx < 0 or (idx + 1) * 4 > tag.rawBytes.len: return int.low
  int(readUint32(tag.rawBytes, idx * 4, tag.endian))

proc parseMinoltaMakerNote*(data: openArray[byte]; mnOffset, base: int;
                            endian: TiffEndianness): Table[string, string] =
  result = initTable[string, string]()
  if mnOffset < 0 or mnOffset + 2 > data.len: return
  let ifd = readIFD(data, mnOffset, base, endian)       # bare IFD, outer endian
  for id, tag in ifd.tags:
    case id
    of 0x0000'u16: # MakerNoteVersion: 4-byte ASCII ("MLT0")
      let v = tag.toString().strip()
      if v.len > 0: result["Minolta:MakerNoteVersion"] = v
    of 0x0040'u16: # CompressedImageSize: raw byte count
      let v = tag.toString().strip()
      if v.len > 0: result["Minolta:CompressedImageSize"] = v
    of 0x0089'u16: # PreviewImageLength: raw byte count
      let v = tag.toString().strip()
      if v.len > 0: result["Minolta:PreviewImageLength"] = v
    else: discard

  # CameraSettings (new) array, tag 0x0003: big-endian int32, id == index.
  if ifd.tags.hasKey(0x0003'u16):
    let cs = ifd.tags[0x0003'u16]
    template enumField(idx: int; m: Table[int, string]; name: string) =
      let val = minoltaArr(cs, idx)
      if m.hasKey(val): result["Minolta:" & name] = m[val]
    enumField(2, MinoltaFlashMode, "FlashMode")
    enumField(3, MinoltaWhiteBalance, "WhiteBalance")
    enumField(4, MinoltaImageSize, "MinoltaImageSize")
    enumField(5, MinoltaQuality, "MinoltaQuality")
    enumField(6, MinoltaDriveMode, "DriveMode")
    enumField(11, MinoltaOnOff, "MacroMode")
    enumField(12, MinoltaDigitalZoom, "DigitalZoom")
    enumField(20, MinoltaNoYes, "FlashFired")
    enumField(26, MinoltaOnOff, "FileNumberMemory")
    enumField(34, MinoltaSubjectProgram, "SubjectProgram")
    enumField(37, MinoltaModelID, "MinoltaModelID")
    enumField(38, MinoltaIntervalMode, "IntervalMode")
    enumField(39, MinoltaFolderName, "FolderName")
    enumField(40, MinoltaColorMode, "ColorMode")
    enumField(43, MinoltaInternalFlash, "InternalFlash")
    enumField(47, MinoltaWideFocusZone, "WideFocusZone")
    enumField(48, MinoltaFocusMode, "FocusMode")
    enumField(49, MinoltaFocusArea, "FocusArea")
    enumField(50, MinoltaDECPosition, "DECPosition")
    # MinoltaDate (idx 21) / MinoltaTime (idx 22): packed (Y<<16)|(M<<8)|D etc.
    let dpk = minoltaArr(cs, 21)
    if dpk != int.low and dpk > 0:
      result["Minolta:MinoltaDate"] =
        align($((dpk shr 16) and 0xFFFF), 4, '0') & ":" &
        align($((dpk shr 8) and 0xFF), 2, '0') & ":" & align($(dpk and 0xFF), 2, '0')
    let tpk = minoltaArr(cs, 22)
    if tpk != int.low and tpk > 0:
      result["Minolta:MinoltaTime"] =
        align($((tpk shr 16) and 0xFF), 2, '0') & ":" &
        align($((tpk shr 8) and 0xFF), 2, '0') & ":" & align($(tpk and 0xFF), 2, '0')

# --- Sigma -----------------------------------------------------------------
#
# Header "SIGMA\0\0\0" (8 bytes) + a 2-byte version word, then the IFD at offset
# 10 (exiftool's documented Start). Value offsets are relative to the OUTER TIFF
# base and the IFD uses the outer byte order (verified on a real SD10). Almost
# every value is stored as ASCII.
#
# Two faithful transforms exiftool applies, replicated here:
#   * "labelled" numeric tags are stored as "Label:value" (e.g. "Expo:+0.8");
#     exiftool drops the label, so we emit the part after the colon.
#   * MeteringMode is a single-character enum ("8"/"A"/"C").
# Plain strings (SerialNumber, DriveMode, AFMode, …) are emitted verbatim. Tags
# exiftool does not surface for this model (0x0008, 0x000b, 0x0018) are skipped.

const
  SigmaMetering = {"8": "Multi-segment", "A": "Average",
                   "C": "Center-weighted average"}.toTable
  SigmaExposureMode = {"P": "Program", "A": "Aperture Priority",
                       "S": "Shutter Speed Priority", "M": "Manual"}.toTable

proc afterColon(s: string): string =
  ## "Expo:+0.8" -> "+0.8"; a string with no colon is returned stripped as-is.
  let i = s.find(':')
  if i < 0: s.strip() else: s[i+1 .. ^1].strip()

proc parseSigmaMakerNote*(data: openArray[byte]; mnOffset, base: int;
                          endian: TiffEndianness): Table[string, string] =
  result = initTable[string, string]()
  const hdr = "SIGMA\0\0\0"
  if mnOffset < 0 or mnOffset + 10 > data.len: return
  for i in 0 ..< hdr.len:
    if data[mnOffset + i] != byte(hdr[i]): return
  let ifd = readIFD(data, mnOffset + 10, base, endian) # base = outer TIFF base
  for id, tag in ifd.tags:
    let raw = tag.toString().strip()
    case id
    of 0x0002'u16: (if raw.len > 0: result["Sigma:SerialNumber"] = raw)
    of 0x0003'u16: (if raw.len > 0: result["Sigma:DriveMode"] = raw)
    of 0x0004'u16: (if raw.len > 0: result["Sigma:ResolutionMode"] = raw)
    of 0x0005'u16: (if raw.len > 0: result["Sigma:AFMode"] = raw)
    of 0x0006'u16: (if raw.len > 0: result["Sigma:FocusSetting"] = raw)
    of 0x0007'u16: (if raw.len > 0: result["Sigma:WhiteBalance"] = raw)
    of 0x0008'u16: (if SigmaExposureMode.hasKey(raw): result[
        "Sigma:ExposureMode"] = SigmaExposureMode[raw])
    of 0x0009'u16: (if SigmaMetering.hasKey(raw): result[
        "Sigma:MeteringMode"] = SigmaMetering[raw])
    of 0x000b'u16: (if raw.len > 0: result["Sigma:ColorSpace"] = raw)
    of 0x000a'u16: (if raw.len > 0: result["Sigma:LensFocalRange"] = raw)
    of 0x000c'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:ExposureCompensation"] = v))
    of 0x000d'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:Contrast"] = v))
    of 0x000e'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:Shadow"] = v))
    of 0x000f'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:Highlight"] = v))
    of 0x0010'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:Saturation"] = v))
    of 0x0011'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:Sharpness"] = v))
    of 0x0012'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:X3FillLight"] = v))
    of 0x0014'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:ColorAdjustment"] = v))
    of 0x0015'u16: (if raw.len > 0: result["Sigma:AdjustmentMode"] = raw)
    of 0x0016'u16: (let v = afterColon(raw); (if v.len > 0: result[
        "Sigma:Quality"] = v))
    of 0x0017'u16: (if raw.len > 0: result["Sigma:Firmware"] = raw)
    else: discard

# --- vendor dispatch -------------------------------------------------------

proc parseMakerNote*(make: string; data: openArray[byte]; mnOffset, base: int;
                     endian: TiffEndianness; model = ""): Table[string, string] =
  ## Dispatch to a vendor MakerNote decoder by EXIF Make. Returns an empty table
  ## for an unknown vendor (the caller then falls back to a raw hex dump). Apple
  ## is handled by the caller separately (its offsets are blob-relative). `model`
  ## gates model-specific sub-blocks (e.g. Pentax K10D CameraSettings fields).
  if make.len == 0: return initTable[string, string]()
  let m = make.toLowerAscii()
  if m.contains("canon"): return parseCanonMakerNote(data, mnOffset, base, endian)
  if m.contains("nikon"): return parseNikonMakerNote(data, mnOffset, base, endian)
  if m.contains("panasonic"): return parsePanasonicMakerNote(data, mnOffset,
      base, endian)
  if m.contains("fuji"): return parseFujiMakerNote(data, mnOffset)
  if m.contains("pentax"): return parsePentaxMakerNote(data, mnOffset, base,
      endian, model)
  if m.contains("olympus"): return parseOlympusMakerNote(data, mnOffset, base, endian)
  if m.contains("casio"): return parseCasioMakerNote(data, mnOffset, base, endian)
  if m.contains("minolta"): return parseMinoltaMakerNote(data, mnOffset, base, endian)
  if m.contains("sigma"): return parseSigmaMakerNote(data, mnOffset, base, endian)
  initTable[string, string]()
