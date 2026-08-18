# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Decoding HEIC and AVIF through the system's own decoder, on macOS.
##
## The rest of this library implements the formats it reads. This module does
## not: HEVC and AV1 are what a HEIF file holds, and writing a decoder for
## either would mean either an enormous amount of code or, for HEVC, a patent
## licence that every consumer would inherit. Calling the decoder the operating
## system already licenses avoids both — the picture comes back as pixels, and
## whatever obligation the codec carries stays with Apple's own implementation.
##
## **Opt-in, and macOS only.** Nothing here compiles unless `-d:appleCodecs` is
## given, so the default build links no framework and stays portable. A caller
## that wants system decoding asks for it and accepts what that means for where
## its binary runs.
##
## `formats/heif` still answers what a picture *is* — size, orientation, coding
## — everywhere, without this. Only the pixels need the system.

when not defined(macosx):
  {.error: "heif_apple is macOS only; guard it with `when defined(macosx)`".}

import ../core
import ./heif

{.passL: "-framework ImageIO -framework CoreFoundation -framework CoreGraphics".}

type
  CFTypeRef = pointer
  CFDataRef = pointer
  CGImageSourceRef = pointer
  CGImageRef = pointer
  CGColorSpaceRef = pointer
  CGContextRef = pointer

const
  # kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault: RGBA, eight bits
  # a channel, which is the one layout every caller here wants.
  AlphaPremultipliedLast = 1'u32

proc CFDataCreate(allocator: pointer; bytes: ptr uint8;
                  length: int): CFDataRef {.importc, cdecl.}
proc CFRelease(cf: CFTypeRef) {.importc, cdecl.}
proc CGImageSourceCreateWithData(data: CFDataRef;
                                 options: pointer): CGImageSourceRef
    {.importc, cdecl.}
proc CGImageSourceCreateImageAtIndex(source: CGImageSourceRef; index: int;
                                     options: pointer): CGImageRef
    {.importc, cdecl.}
proc CGImageGetWidth(image: CGImageRef): int {.importc, cdecl.}
proc CGImageGetHeight(image: CGImageRef): int {.importc, cdecl.}
proc CGColorSpaceCreateDeviceRGB(): CGColorSpaceRef {.importc, cdecl.}
proc CGColorSpaceRelease(space: CGColorSpaceRef) {.importc, cdecl.}
proc CGBitmapContextCreate(data: pointer; width, height, bitsPerComponent,
                           bytesPerRow: int; space: CGColorSpaceRef;
                           bitmapInfo: uint32): CGContextRef {.importc, cdecl.}
proc CGContextRelease(context: CGContextRef) {.importc, cdecl.}
proc CGImageRelease(image: CGImageRef) {.importc, cdecl.}

type CGRect {.bycopy.} = object
  x, y, width, height: float64

proc CGContextDrawImage(context: CGContextRef; rect: CGRect;
                        image: CGImageRef) {.importc, cdecl.}

proc appleCodecsAvailable*(): bool =
  ## Whether this build carries the system decoder. Always true here, because
  ## the module does not compile otherwise — a caller tests it through
  ## `when defined(appleCodecs)` rather than at run time.
  true

proc decodeHeifApple*(data: openArray[byte]): Image[uint8] =
  ## Decode a HEIC or AVIF to straight RGBA through ImageIO.
  ##
  ## Raises `UniImageException` when the system refuses the file — which is a
  ## real answer, not a failure of this library: a Mac without the HEVC
  ## components installed cannot decode HEIC, and saying so is better than
  ## returning something wrong.
  ##
  ## The picture comes back already oriented: ImageIO applies the container's
  ## rotation, so a caller must not apply `HeifImage.rotation` on top of it.
  if data.len == 0:
    raise UniImageException(code: uiTruncated, msg: "heif: empty input")
  if not isHeif(data):
    raise UniImageException(code: uiUnsupported, msg: "heif: not a HEIF file")

  let cfData = CFDataCreate(nil, unsafeAddr data[0], data.len)
  if cfData == nil:
    raise UniImageException(code: uiInvalidArg, msg: "heif: cannot wrap input")
  defer: CFRelease(cfData)

  let source = CGImageSourceCreateWithData(cfData, nil)
  if source == nil:
    raise UniImageException(code: uiUnsupported,
      msg: "heif: the system did not recognise this file")
  defer: CFRelease(source)

  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  if image == nil:
    raise UniImageException(code: uiUnsupported,
      msg: "heif: the system has no decoder for this codec")
  defer: CGImageRelease(image)

  let width = CGImageGetWidth(image)
  let height = CGImageGetHeight(image)
  if width <= 0 or height <= 0:
    raise UniImageException(code: uiInvalidArg, msg: "heif: empty picture")

  result = newImage[uint8](width, height, csRgba)
  let space = CGColorSpaceCreateDeviceRGB()
  if space == nil:
    raise UniImageException(code: uiInvalidArg, msg: "heif: no colour space")
  defer: CGColorSpaceRelease(space)

  let context = CGBitmapContextCreate(addr result.data[0], width, height, 8,
    width * 4, space, AlphaPremultipliedLast)
  if context == nil:
    raise UniImageException(code: uiInvalidArg,
      msg: "heif: cannot address a bitmap of that size")
  defer: CGContextRelease(context)

  CGContextDrawImage(context, CGRect(x: 0.0, y: 0.0, width: float64(width),
    height: float64(height)), image)
