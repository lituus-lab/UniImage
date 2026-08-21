# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniImage build config.
##
## On macOS the system HEIC and AVIF decoders are on by default: the frameworks
## are part of the operating system, and a Mac build that cannot open a HEIC is
## the wrong default for a library whose consumers catalogue photographs.
## `-d:noAppleCodecs` turns them off for a build that must link nothing.
##
## Elsewhere nothing changes: `formats/heif` still says what a picture is
## without any decoder, and asking for pixels raises rather than guessing.
when defined(macosx) and not defined(noAppleCodecs):
  switch("define", "appleCodecs")
switch("path", "../UniChecksum/src")
switch("path", "../UniCompress/src")
