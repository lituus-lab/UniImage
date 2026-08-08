# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[unittest, base64]
import UniImage/core
import UniImage

# A 2x2 RGB JPEG thumbnail (PIL, quality 80) embedded two ways: once as a TIFF
# IFD1 thumbnail, once as a JPEG APP1 EXIF IFD1 thumbnail. Both containers point
# at the same embedded JPEG bytes, so extraction must be byte-identical and
# container-independent. PIL's libjpeg decode of the embedded JPEG is the pixel
# oracle (within IDCT rounding); our decoder is deterministic, so the exact
# values it produces are asserted.
const TiffThumbB64 = "SUkqAAgAAAAJAAABAwABAAAAAQAAAAEBAwABAAAAAQAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAAegAAABUBAwABAAAAAQAAABYBBAABAAAAAQAAABcBBAABAAAAAQAAAHsAAACAAgABAgQAAQAAAJkAAAACAgQAAQAAAJQCAAAAAAAA/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDP8P3Ex0HTSZpCTbRfxH+4KKKK/PsV/Hn6v8zxsR/Fl6v8z//Z"
const JpegThumbB64 = "/9j/4cgCRXhpZgAASUkqAAgAAAAAAA4AAAACAAECBAABAAAALAAAAAICBAABAAAAlAIAAAAAAAD/2P/gABBKRklGAAEBAAABAAEAAP/bAEMABgQFBgUEBgYFBgcHBggKEAoKCQkKFA4PDBAXFBgYFxQWFhodJR8aGyMcFhYgLCAjJicpKikZHy0wLSgwJSgpKP/bAEMBBwcHCggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKP/AABEIAAIAAgMBIgACEQEDEQH/xAAfAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgv/xAC1EAACAQMDAgQDBQUEBAAAAX0BAgMABBEFEiExQQYTUWEHInEUMoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4eLj5OXm5+jp6vHy8/T19vf4+fr/xAAfAQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1EQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/AM/w/cTHQdNJmkJNtF/Ef7gooor8+xX8efq/zPGxH8WXq/zP/9n/2Q=="
const NoExifB64 = "/9j/2Q=="
  # Plain 4x3 grayscale TIFF (no IFD1): an EXIF base exists, but there is no
  # embedded thumbnail, so loadThumbnail raises uiUnsupported.
const NoThumbTiffB64 = "SUkqAAgAAAAJAAABBAABAAAABAAAAAEBBAABAAAAAwAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAAegAAABYBBAABAAAAAwAAABcBBAABAAAADAAAABwBAwABAAAAAQAAAAAAAAAKFB4oMjxGUFpkbng="

const ExpectedPx = [(86'u8, 62'u8, 44'u8), (177'u8, 154'u8, 135'u8),
                    (54'u8, 31'u8, 12'u8), (147'u8, 123'u8, 105'u8)]

proc b64(s: string): seq[byte] =
  let raw = decode(s)
  result = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr result[0], unsafeAddr raw[0], raw.len)

suite "exif thumbnail":
  test "PNG and WebP without EXIF report no TIFF base":
    check exifTiffBase(@[byte 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A,
      0x0A]) == -1
    check exifTiffBase(@[byte 0x52, 0x49, 0x46, 0x46, 0x04, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50]) == -1

  test "extraction is byte-exact and container-independent":
    let t = extractExifThumbnail(b64(TiffThumbB64))
    let j = extractExifThumbnail(b64(JpegThumbB64))
    check t.len == 660
    check j.len == 660
    check t == j

  test "loadThumbnail decodes the TIFF-embedded JPEG":
    let img = loadThumbnail(b64(TiffThumbB64))
    check img.width == 2 and img.height == 2
    check img.channels == 3 and img.colorspace == csRgb
    for i in 0 ..< 4:
      let (r, g, b) = ExpectedPx[i]
      check img.data[i * 3] == r
      check img.data[i * 3 + 1] == g
      check img.data[i * 3 + 2] == b

  test "loadThumbnail decodes the JPEG-APP1-embedded JPEG":
    let img = loadThumbnail(b64(JpegThumbB64))
    check img.width == 2 and img.height == 2
    check img.channels == 3 and img.colorspace == csRgb
    for i in 0 ..< 4:
      let (r, g, b) = ExpectedPx[i]
      check img.data[i * 3] == r
      check img.data[i * 3 + 1] == g
      check img.data[i * 3 + 2] == b

  test "no EXIF segment raises uiUnsupported":
    try:
      discard loadThumbnail(b64(NoExifB64))
      check false
    except UniImageException as e:
      check e.code == uiUnsupported

  test "EXIF present but no IFD1 thumbnail raises uiUnsupported":
    try:
      discard loadThumbnail(b64(NoThumbTiffB64))
      check false
    except UniImageException as e:
      check e.code == uiUnsupported
