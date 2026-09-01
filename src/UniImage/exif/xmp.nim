# SPDX-License-Identifier: Apache-2.0

## XMP (Adobe metadata) read/write for the common editable Dublin Core fields.
##
## In JPEG, XMP is an APP1 segment whose payload starts with the namespace
## header "http://ns.adobe.com/xap/1.0/\0" followed by an RDF/XML packet. This
## module reads/writes title, description, rights, creator and keywords.

import std/[strutils, xmltree, xmlparser, streams, tables, strtabs, options]
import ./png, ./webp

const XmpHeader* = "http://ns.adobe.com/xap/1.0/\0"

type
  XmpData* = object
    title*: string
    description*: string
    rights*: string
    creator*: seq[string]
    keywords*: seq[string]
    all*: OrderedTable[string, string] ## every property: "prefix:local" -> value

  XmpPatch* = object
    ## Explicit XMP edits. `none` preserves a property; `some("")` removes a
    ## scalar property and `some(@[])` removes a list property.
    title*, description*, rights*: Option[string]
    creator*, keywords*: Option[seq[string]]
    namespaces*: OrderedTable[string, string]
    properties*: OrderedTable[string, Option[string]]

proc readWholeFile(path: string): seq[byte] =
  try:
    let s = readFile(path)
    result = newSeq[byte](s.len)
    if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)
  except CatchableError:
    result = @[]

proc headerMatches(data: openArray[byte]; at: int): bool =
  if at + XmpHeader.len > data.len: return false
  for k in 0 ..< XmpHeader.len:
    if data[at + k] != byte(XmpHeader[k]): return false
  true

proc findXmpApp1(data: openArray[byte]): tuple[offset, length: int] =
  ## Payload offset/length of the APP1 XMP segment (after the namespace header).
  if data.len < 4 or data[0] != 0xFF or data[1] != 0xD8: return (0, 0)
  var i = 2
  while i + 4 < data.len:
    if data[i] != 0xFF: break
    let marker = data[i + 1]
    if marker == 0xDA: break
    let length = (int(data[i + 2]) shl 8) or int(data[i + 3])
    if marker == 0xE1 and headerMatches(data, i + 4):
      return (i + 4 + XmpHeader.len, length - 2 - XmpHeader.len)
    i += length + 2
  (0, 0)

# --- parse -----------------------------------------------------------------

proc firstLi(node: XmlNode): string =
  for c in node.findAll("rdf:li"):
    return c.innerText.strip()
  node.innerText.strip()

proc allLi(node: XmlNode): seq[string] =
  for c in node.findAll("rdf:li"):
    let t = c.innerText.strip()
    if t.len > 0: result.add t

proc parseXmp*(xml: string): XmpData =
  ## Parse an XMP packet. Malformed XML yields an empty result rather than
  ## raising: XMP travels inside image files written by anything, and a
  ## packet that will not parse is a reason to fall back to EXIF, not to
  ## refuse the file.
  var root: XmlNode
  try: root = parseXml(newStringStream(xml))
  except CatchableError: return
  if root == nil: return
  for n in root.findAll("dc:title"): result.title = firstLi(n); break
  for n in root.findAll("dc:description"): result.description = firstLi(n); break
  for n in root.findAll("dc:rights"): result.rights = firstLi(n); break
  for n in root.findAll("dc:creator"): result.creator = allLi(n); break
  for n in root.findAll("dc:subject"): result.keywords = allLi(n); break
  # Generic: every property on each rdf:Description, both attribute-form
  # (prefix:local="value") and element-form (<prefix:local>...</prefix:local>,
  # with rdf:Alt/Bag/Seq lists joined by ", "). Keyed "prefix:local".
  for desc in root.findAll("rdf:Description"):
    if desc.attrs != nil:
      for k, v in desc.attrs:
        if ':' notin k or k.startsWith("xmlns") or k.startsWith(
            "rdf:"): continue
        if v.strip().len > 0: result.all[k] = v.strip()
    for child in desc:
      if child.kind != xnElement: continue
      let tag = child.tag
      if ':' notin tag or tag.startsWith("rdf:"): continue
      let lis = allLi(child)
      let v = if lis.len > 0: lis.join(", ") else: child.innerText.strip()
      if v.len > 0: result.all[tag] = v

proc readXmpBytes*(data: openArray[byte]): XmpData =
  ## Locate and parse the XMP packet from an in-memory image buffer.
  if isPng(data):
    let xml = findXmpInPng(data)
    if xml.len > 0: return parseXmp(xml)
    return
  if isWebp(data):
    let xml = findXmpInWebp(data)
    if xml.len > 0: return parseXmp(xml)
    return
  let (off, len) = findXmpApp1(data)
  if off <= 0 or len <= 0 or off + len > data.len: return
  var xml = newString(len)
  for k in 0 ..< len: xml[k] = char(data[off + k])
  parseXmp(xml)

proc readXmp*(path: string): XmpData =
  ## The XMP packet of a file on disk, whichever container holds it -- PNG
  ## in an `iTXt` chunk, WebP in the chunk whose four-character code is
  ## `XMP` followed by a space, JPEG in an APP1 segment.
  let data = readWholeFile(path)
  if isPng(data):
    let xml = findXmpInPng(data) # iTXt "XML:com.adobe.xmp"
    if xml.len > 0: return parseXmp(xml)
    return
  if isWebp(data):
    let xml = findXmpInWebp(data) # RIFF "XMP " chunk
    if xml.len > 0: return parseXmp(xml)
    return
  let (off, len) = findXmpApp1(data)
  if off <= 0 or len <= 0 or off + len > data.len: return
  var xml = newString(len)
  for k in 0 ..< len: xml[k] = char(data[off + k])
  parseXmp(xml)

# --- build / write ---------------------------------------------------------

proc esc(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

const XmpNamespaces = {
  "dc": "http://purl.org/dc/elements/1.1/",
  "xmp": "http://ns.adobe.com/xap/1.0/",
  "photoshop": "http://ns.adobe.com/photoshop/1.0/",
  "Iptc4xmpCore": "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
  "xmpRights": "http://ns.adobe.com/xap/1.0/rights/",
  "tiff": "http://ns.adobe.com/tiff/1.0/",
  "exif": "http://ns.adobe.com/exif/1.0/",
  "aux": "http://ns.adobe.com/exif/1.0/aux/",
  "lr": "http://ns.adobe.com/lightroom/1.0/",
}.toTable

# dc properties emitted structurally below (skipped in the generic all-loop).
const DcStructured = ["dc:title", "dc:description", "dc:rights", "dc:creator",
                      "dc:subject"]

proc buildXmp*(x: XmpData): string =
  ## Serialise back to an XMP packet, declaring every namespace actually
  ## used rather than a fixed list: a reader that meets an undeclared prefix
  ## is entitled to reject the whole packet.
  result = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
  result.add "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n"
  result.add " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
  # Declare every namespace used (dc always; plus any prefix present in x.all).
  var prefixes = @["dc"]
  for key in x.all.keys:
    let p = key.split(':', 1)[0]
    if p notin prefixes and XmpNamespaces.hasKey(p): prefixes.add p
  result.add "  <rdf:Description"
  for p in prefixes: result.add " xmlns:" & p & "=\"" & XmpNamespaces[p] & "\""
  result.add ">\n"
  if x.title.len > 0:
    result.add "   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">" &
      esc(x.title) & "</rdf:li></rdf:Alt></dc:title>\n"
  if x.description.len > 0:
    result.add "   <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">" &
      esc(x.description) & "</rdf:li></rdf:Alt></dc:description>\n"
  if x.rights.len > 0:
    result.add "   <dc:rights><rdf:Alt><rdf:li xml:lang=\"x-default\">" &
      esc(x.rights) & "</rdf:li></rdf:Alt></dc:rights>\n"
  if x.creator.len > 0:
    result.add "   <dc:creator><rdf:Seq>"
    for c in x.creator: result.add "<rdf:li>" & esc(c) & "</rdf:li>"
    result.add "</rdf:Seq></dc:creator>\n"
  if x.keywords.len > 0:
    result.add "   <dc:subject><rdf:Bag>"
    for k in x.keywords: result.add "<rdf:li>" & esc(k) & "</rdf:li>"
    result.add "</rdf:Bag></dc:subject>\n"
  # Generic simple properties from x.all (other schemas, e.g. xmp:Rating,
  # photoshop:City). dc structured fields above are skipped; unknown prefixes too.
  for key, value in x.all:
    if key in DcStructured or value.len == 0: continue
    if not XmpNamespaces.hasKey(key.split(':', 1)[0]): continue
    result.add "   <" & key & ">" & esc(value) & "</" & key & ">\n"
  result.add "  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>"

proc mergeXmp*(xml: string; patch: XmpPatch): string =
  ## Apply selected fields while preserving unrelated elements, attributes and
  ## namespace declarations from an existing packet.
  var root: XmlNode
  try:
    root = parseXml(newStringStream(xml))
  except CatchableError as error:
    raise newException(ValueError, "invalid XMP packet: " & error.msg)
  if root == nil:
    raise newException(ValueError, "invalid XMP packet")
  let descriptions = root.findAll("rdf:Description")
  if descriptions.len == 0:
    raise newException(ValueError, "XMP packet has no rdf:Description")
  let target = descriptions[0]

  proc declareNamespace(prefix, uri: string) =
    if target.attrs == nil: target.attrs = newStringTable(modeCaseSensitive)
    target.attrs["xmlns:" & prefix] = uri

  proc validNamePart(value: string): bool =
    if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_'):
      return false
    for index in 1 ..< value.len:
      let ch = value[index]
      if not (ch.isAlphaNumeric or ch in {'_', '-', '.'}): return false
    true

  proc removeProperty(tag: string) =
    for desc in descriptions:
      if desc.attrs != nil: desc.attrs.del(tag)
      var index = desc.len - 1
      while index >= 0:
        if desc[index].kind == xnElement and desc[index].tag == tag:
          desc.delete(index)
        dec index

  proc addAlt(tag, value: string) =
    if value.len == 0: return
    declareNamespace("dc", XmpNamespaces["dc"])
    let li = newXmlTree("rdf:li", [newText(value)],
      {"xml:lang": "x-default"}.toXmlAttributes)
    target.add newXmlTree(tag, [newXmlTree("rdf:Alt", [li])])

  proc addList(tag, container: string; values: seq[string]) =
    if values.len == 0: return
    let list = newElement(container)
    for value in values:
      if value.len > 0: list.add newXmlTree("rdf:li", [newText(value)])
    if list.len > 0:
      declareNamespace("dc", XmpNamespaces["dc"])
      target.add newXmlTree(tag, [list])

  template replaceScalar(field: untyped; tag: string) =
    if field.isSome:
      removeProperty(tag)
      addAlt(tag, field.get())

  replaceScalar(patch.title, "dc:title")
  replaceScalar(patch.description, "dc:description")
  replaceScalar(patch.rights, "dc:rights")
  if patch.creator.isSome:
    removeProperty("dc:creator")
    addList("dc:creator", "rdf:Seq", patch.creator.get())
  if patch.keywords.isSome:
    removeProperty("dc:subject")
    addList("dc:subject", "rdf:Bag", patch.keywords.get())
  for key, value in patch.properties:
    let parts = key.split(':')
    if parts.len != 2 or not validNamePart(parts[0]) or
        not validNamePart(parts[1]) or key in DcStructured:
      raise newException(ValueError, "invalid simple XMP property: " & key)
    let prefix = parts[0]
    let namespaceUri = if patch.namespaces.hasKey(prefix): patch.namespaces[prefix]
                       elif XmpNamespaces.hasKey(prefix): XmpNamespaces[prefix]
                       else: ""
    if namespaceUri.len == 0:
      raise newException(ValueError, "unknown XMP namespace prefix: " & prefix)
    removeProperty(key)
    if value.isSome and value.get().len > 0:
      declareNamespace(prefix, namespaceUri)
      target.add newXmlTree(key, [newText(value.get())])
  $root

proc embedXmpInJpeg(orig: seq[byte]; packet: string): seq[byte] =
  let payload = XmpHeader & packet
  let segLen = 2 + payload.len
  var app1 = @[byte 0xFF, 0xE1, byte((segLen shr 8) and 0xFF), byte(segLen and 0xFF)]
  for c in payload: app1.add byte(c)

  result.add orig[0]; result.add orig[1]
  var i = 2
  var inserted = false
  while i + 4 <= orig.len:
    if orig[i] != 0xFF: break
    let marker = orig[i + 1]
    if marker == 0xDA:
      if not inserted: result.add app1
      result.add orig[i ..< orig.len]
      return
    let segLength = (int(orig[i + 2]) shl 8) or int(orig[i + 3])
    if i + 2 + segLength > orig.len: break
    if marker == 0xE1 and headerMatches(orig, i + 4):
      result.add app1; inserted = true # replace existing XMP
    else:
      result.add orig[i ..< i + 2 + segLength]
    i += 2 + segLength
  if not inserted: result.add app1
  if i < orig.len: result.add orig[i ..< orig.len]

proc writeXmp*(path: string; x: XmpData; outPath = ""): bool =
  ## Embed an XMP packet into a JPEG (alongside any Exif), replacing an existing
  ## XMP segment. Returns false for non-JPEG or oversized packets.
  let dst = if outPath.len > 0: outPath else: path
  let data = readWholeFile(path)
  if data.len < 2 or data[0] != 0xFF or data[1] != 0xD8: return false
  let packet = buildXmp(x)
  if 2 + XmpHeader.len + packet.len > 0xFFFF: return false
  let output = embedXmpInJpeg(data, packet)
  try: writeFile(dst, cast[string](output)) except CatchableError: return false
  true
