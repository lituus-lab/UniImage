# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The version, stated in four places, checked to agree.
##
## Nimble refuses anything but a string literal for `version`, so the manifest
## cannot import a shared constant and no arrangement makes one file the source
## the others derive from. What is achievable is proof: this test reads every
## copy and fails when one drifts, which is what a release needs before it can
## claim manifest = header = wheel = tag.
import std/[unittest, os, strutils]
import UniImage

const Root = currentSourcePath().parentDir.parentDir

proc valueOf(path, key, opener, closer: string): string =
  ## The first `key … opener VALUE closer` on one line of the file; an empty
  ## `closer` reads to the end of the line. Deliberately crude: a parser per
  ## format would be more code than the thing it checks.
  for line in readFile(Root / path).splitLines:
    let at = line.find(key)
    if at < 0: continue
    let opens = line.find(opener, at + key.len)
    if opens < 0: continue
    let value = line[opens + opener.len .. ^1]
    if closer.len == 0: return value.strip
    let closes = value.find(closer)
    if closes < 0: continue
    return value[0 ..< closes]
  ""

suite "one version, four copies":
  let manifest = valueOf("UniImage.nimble", "version", "\"", "\"")

  test "the manifest states one":
    check manifest.len > 0
    check manifest.count('.') == 2

  test "the Nim constant agrees":
    check UniImageVersion == manifest

  test "the C header carries no package version":
    # It declares only ABI versions, which move on their own schedule: an ABI
    # break is not a release and a release is not an ABI break.
    let header = readFile(Root / "include/UniImage.h")
    check "UNIIMAGE_EXIF_ABI_VERSION" in header
    check ("\"" & manifest & "\"") notin header

  test "the C ABI reports it":
    let source = readFile(Root / "src/UniImage/c_api.nim")
    check "UniImageVersion" in source

  test "the Python distribution agrees":
    check valueOf("py/pyproject.toml", "version", "\"", "\"") == manifest

  test "the Python test expects it":
    check valueOf("py/tests/test_exif.py", "uniimage.version()", "\"",
        "\"") == manifest
