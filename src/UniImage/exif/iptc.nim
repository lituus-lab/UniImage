# SPDX-License-Identifier: Apache-2.0

## IPTC-IIM metadata read (JPEG APP13 / Photoshop 8BIM resource 0x0404).
##
## Legacy but still widely used by agencies and stock libraries for caption,
## keywords, byline (creator), copyright and location. Read-only.

import ./endian
import std/tables

type
  IptcData* = object
    title*: string                     ## 2:05  Object Name
    caption*: string                   ## 2:120 Caption / Abstract
    headline*: string                  ## 2:105 Headline
    keywords*: seq[string]             ## 2:25  Keywords (repeatable)
    byline*: seq[string]               ## 2:80  By-line (creator, repeatable)
    copyright*: string                 ## 2:116 Copyright Notice
    credit*: string                    ## 2:110 Credit
    source*: string                    ## 2:115 Source
    city*: string                      ## 2:90  City
    state*: string                     ## 2:95  Province / State
    country*: string                   ## 2:101 Country / Primary Location Name
    all*: OrderedTable[string, string] ## every decoded record-2 dataset by name
                                       ## (repeatable values joined with ", ")

const PhotoshopSig = "Photoshop 3.0\0"

# IPTC-IIM record 2 (Application) dataset -> name. Matches exiftool/exiv2 naming
# for the commonly-used datasets; values emitted verbatim (no enum PrintConv, so
# they agree with exiv2 — exiftool adds "(...)" descriptions on a few like Urgency).
const IptcNames = {
  0: "ApplicationRecordVersion", 5: "ObjectName", 7: "EditStatus",
  10: "Urgency", 12: "SubjectReference", 15: "Category",
  20: "SupplementalCategories", 22: "FixtureIdentifier", 25: "Keywords",
  26: "ContentLocationCode", 27: "ContentLocationName", 30: "ReleaseDate",
  35: "ReleaseTime", 37: "ExpirationDate", 38: "ExpirationTime",
  40: "SpecialInstructions", 42: "ActionAdvised", 45: "ReferenceService",
  47: "ReferenceDate", 50: "ReferenceNumber", 55: "DateCreated",
  60: "TimeCreated", 62: "DigitalCreationDate", 63: "DigitalCreationTime",
  65: "OriginatingProgram", 70: "ProgramVersion", 75: "ObjectCycle",
  80: "By-line", 85: "By-lineTitle", 90: "City", 92: "Sub-location",
  95: "Province-State", 100: "Country-PrimaryLocationCode",
  101: "Country-PrimaryLocationName", 103: "OriginalTransmissionReference",
  105: "Headline", 110: "Credit", 115: "Source", 116: "CopyrightNotice",
  118: "Contact", 120: "Caption-Abstract", 122: "Writer-Editor",
  130: "ImageType", 131: "ImageOrientation", 135: "LanguageIdentifier",
}.toTable

const IptcNamesRev = block:
  var t: Table[string, int]
  for k, v in IptcNames: t[v] = k
  t

proc be16s(v: int): seq[byte] = @[byte((v shr 8) and 0xFF), byte(v and 0xFF)]
proc be32s(v: int): seq[byte] =
  @[byte((v shr 24) and 0xFF), byte((v shr 16) and 0xFF),
    byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc buildIimDatasets*(items: seq[(string, string)]): seq[byte] =
  ## Build IPTC-IIM record-2 datasets (each: 0x1C 0x02 <ds> <len:2> <value>).
  ## ApplicationRecordVersion (2:00 = 4) is emitted first. Unknown names are
  ## skipped; pass an item more than once for repeatable tags (e.g. Keywords).
  result.add @[byte 0x1C, 2, 0] & be16s(2) & @[byte 0, 4] # 2:00 version = 4
  for (name, value) in items:
    if name == "ApplicationRecordVersion" or not IptcNamesRev.hasKey(name): continue
    var vb: seq[byte]
    for c in value: vb.add byte(c)
    if vb.len > 0x7FFF: vb.setLen(0x7FFF)
    result.add @[byte 0x1C, 2, byte(IptcNamesRev[name])] & be16s(vb.len) & vb

proc setIptcInJpeg*(orig: openArray[byte]; items: seq[(string, string)]): seq[byte] =
  ## Return `orig` (a JPEG) with its IPTC replaced by `items`, as a Photoshop
  ## 8BIM (0x0404) resource in an APP13 segment placed before the scan. Any
  ## existing APP13 is dropped. Returns `@[]` for non-JPEG input.
  if orig.len < 2 or orig[0] != 0xFF or orig[1] != 0xD8: return @[]
  var body: seq[byte]
  for c in PhotoshopSig: body.add byte(c)
  body.add @[byte('8'), byte('B'), byte('I'), byte('M')]
  body.add be16s(0x0404)
  body.add @[byte 0, 0] # empty Pascal name (even)
  let iim = buildIimDatasets(items)
  body.add be32s(iim.len)
  body.add iim
  if iim.len mod 2 == 1: body.add 0 # resource data padded to even
  if body.len + 2 > 0xFFFF: return @[]
  let app13 = @[byte 0xFF, 0xED] & be16s(body.len + 2) & body
  result.add orig[0]; result.add orig[1] # SOI
  var i = 2
  while i + 4 <= orig.len:
    if orig[i] != 0xFF: break
    let marker = orig[i + 1]
    if marker == 0xDA: # SOS: insert before the scan
      result.add app13
      result.add orig[i ..< orig.len]
      return result
    let segLen = int(readUint16(orig, i + 2, BigEndian))
    if segLen < 2 or i + 2 + segLen > orig.len: break
    if marker != 0xED: # keep everything except old APP13
      result.add orig[i ..< i + 2 + segLen]
    i += 2 + segLen
  result.add app13
  if i < orig.len: result.add orig[i ..< orig.len]

proc findApp13Iptc(data: openArray[byte]): (int, int) =
  ## (offset, length) of the IPTC 8BIM (0x0404) payload inside APP13, or (-1, 0).
  if data.len < 2 or data[0] != 0xFF or data[1] != 0xD8: return (-1, 0)
  var i = 2
  while i + 4 <= data.len:
    if data[i] != 0xFF: break
    let marker = data[i + 1]
    if marker == 0xDA or marker == 0xD9: break # SOS / EOI: image data follows
    let segLen = int(readUint16(data, i + 2, BigEndian))
    if segLen < 2: break
    let payload = i + 4
    let payEnd = payload + segLen - 2
    if marker == 0xED and payEnd <= data.len:
      # APP13: skip the "Photoshop 3.0\0" signature, then scan 8BIM blocks.
      var p = payload
      block sigCheck:
        if p + PhotoshopSig.len > payEnd: break sigCheck
        for k in 0 ..< PhotoshopSig.len:
          if data[p + k] != byte(PhotoshopSig[k]): break sigCheck
        p += PhotoshopSig.len
        while p + 12 <= payEnd:
          if not (data[p] == byte('8') and data[p+1] == byte('B') and
                  data[p+2] == byte('I') and data[p+3] == byte('M')):
            break
          let resId = readUint16(data, p + 4, BigEndian)
          # Pascal name: length byte + name, padded so (1+len) is even.
          var q = p + 6
          let nameLen = int(data[q])
          q += 1 + nameLen
          if (1 + nameLen) mod 2 == 1: q += 1
          if q + 4 > payEnd: break
          let resSize = int(readUint32(data, q, BigEndian))
          q += 4
          if q + resSize > payEnd: break
          if resId == 0x0404:
            return (q, resSize)
          q += resSize
          if resSize mod 2 == 1: q += 1 # data is padded to even
          p = q
    i = payEnd
  (-1, 0)

proc parseIptc*(data: openArray[byte]): IptcData =
  ## Parse IPTC-IIM datasets from a JPEG's APP13 segment.
  let (off, length) = findApp13Iptc(data)
  if off < 0: return
  var i = off
  let stop = off + length
  while i + 5 <= stop:
    if data[i] != 0x1C: # IIM tag marker
      inc i
      continue
    let record = data[i + 1]
    let dataset = data[i + 2]
    let dlen = int(readUint16(data, i + 3, BigEndian))
    let valStart = i + 5
    if dlen > 0x7FFF or valStart + dlen > stop: break # extended sizes unsupported
    var s = ""
    for k in 0 ..< dlen: s.add char(data[valStart + k])
    # ApplicationRecordVersion (2:00) is a binary 2-byte SHORT, not ASCII.
    if record == 2 and dataset == 0 and dlen == 2:
      s = $((int(data[valStart]) shl 8) or int(data[valStart + 1]))
    if record == 2:
      case dataset
      of 5: result.title = s
      of 25: result.keywords.add s
      of 80: result.byline.add s
      of 90: result.city = s
      of 95: result.state = s
      of 101: result.country = s
      of 105: result.headline = s
      of 110: result.credit = s
      of 115: result.source = s
      of 116: result.copyright = s
      of 120: result.caption = s
      else: discard
      # generic table: every known record-2 dataset by name (repeatable -> join)
      if IptcNames.hasKey(int(dataset)):
        let nm = IptcNames[int(dataset)]
        if result.all.hasKey(nm): result.all[nm] = result.all[nm] & ", " & s
        else: result.all[nm] = s
    i = valStart + dlen

proc readIptc*(path: string): IptcData =
  ## Read IPTC-IIM metadata from a JPEG file.
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  parseIptc(bytes)
