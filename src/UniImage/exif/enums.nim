# SPDX-License-Identifier: Apache-2.0

proc getOrientation*(val: int): string =
  case val:
    of 1: "Horizontal (normal)"
    of 2: "Mirror horizontal"
    of 3: "Rotate 180"
    of 4: "Mirror vertical"
    of 5: "Mirror horizontal and rotate 270 CW"
    of 6: "Rotate 90 CW"
    of 7: "Mirror horizontal and rotate 90 CW"
    of 8: "Rotate 270 CW"
    else: $val

proc getResolutionUnit*(val: int): string =
  case val:
    of 1: "None"
    of 2: "inches"
    of 3: "cm"
    else: $val

proc getExposureProgram*(val: int): string =
  case val:
    of 0: "Not Defined"
    of 1: "Manual"
    of 2: "Program AE"
    of 3: "Aperture-priority AE"
    of 4: "Shutter speed priority AE"
    of 5: "Creative (Slow speed)"
    of 6: "Action (High speed)"
    of 7: "Portrait"
    of 8: "Landscape"
    else: $val

proc getMeteringMode*(val: int): string =
  case val:
    of 0: "Unknown"
    of 1: "Average"
    of 2: "Center-weighted average"
    of 3: "Spot"
    of 4: "Multi-spot"
    of 5: "Multi-segment"
    of 6: "Partial"
    of 255: "Other"
    else: $val

proc getLightSource*(val: int): string =
  case val:
    of 0: "Unknown"
    of 1: "Daylight"
    of 2: "Fluorescent"
    of 3: "Tungsten (Incandescent)"
    of 4: "Flash"
    of 9: "Fine weather"
    of 10: "Cloudy"
    of 11: "Shade"
    of 12: "Daylight fluorescent (D 5700 - 7100K)"
    of 13: "Day white fluorescent (N 4600 - 5500K)"
    of 14: "Cool white fluorescent (W 3800 - 4500K)"
    of 15: "White fluorescent (WW 3200 - 3700K)"
    of 16: "Warm white fluorescent (L 2600 - 3200K)"
    of 17: "Standard light A"
    of 18: "Standard light B"
    of 19: "Standard light C"
    of 20: "D55"
    of 21: "D65"
    of 22: "D75"
    of 23: "D50"
    of 24: "ISO studio tungsten"
    of 255: "Other"
    else: $val

proc getWhiteBalance*(val: int): string =
  case val:
    of 0: "Auto"
    of 1: "Manual"
    else: $val

proc getColorSpace*(val: int): string =
  case val:
    of 1: "sRGB"
    of 2: "Adobe RGB"
    of 0xFFFD: "Wide Gamut RGB"
    of 0xFFFE: "ICC Profile"
    of 0xFFFF: "Uncalibrated"
    else: $val

proc getExposureMode*(val: int): string =
  case val:
    of 0: "Auto"
    of 1: "Manual"
    of 2: "Auto bracket"
    else: $val

proc getSceneCaptureType*(val: int): string =
  case val:
    of 0: "Standard"
    of 1: "Landscape"
    of 2: "Portrait"
    of 3: "Night"
    of 4: "Other"
    else: $val

proc getSensingMethod*(val: int): string =
  case val:
    of 1: "Not defined"
    of 2: "One-chip color area"
    of 3: "Two-chip color area"
    of 4: "Three-chip color area"
    of 5: "Color sequential area"
    of 7: "Trilinear"
    of 8: "Color sequential linear"
    else: $val

proc getGpsAltitudeRef*(val: int): string =
  case val:
    of 0: "Above Sea Level"
    of 1: "Below Sea Level"
    else: $val

proc parseFlash*(val: int): string =
  ## EXIF Flash bitmask, decoded via the documented exiftool lookup values (exact
  ## parity). Unmapped combinations render as "Unknown (N)", as exiftool does.
  case val
  of 0x00: "No Flash"
  of 0x01: "Fired"
  of 0x05: "Fired, Return not detected"
  of 0x07: "Fired, Return detected"
  of 0x08: "On, Did not fire"
  of 0x09: "On, Fired"
  of 0x0d: "On, Return not detected"
  of 0x0f: "On, Return detected"
  of 0x10: "Off, Did not fire"
  of 0x14: "Off, Did not fire, Return not detected"
  of 0x18: "Auto, Did not fire"
  of 0x19: "Auto, Fired"
  of 0x1d: "Auto, Fired, Return not detected"
  of 0x1f: "Auto, Fired, Return detected"
  of 0x20: "No flash function"
  of 0x30: "Off, No flash function"
  of 0x41: "Fired, Red-eye reduction"
  of 0x45: "Fired, Red-eye reduction, Return not detected"
  of 0x47: "Fired, Red-eye reduction, Return detected"
  of 0x49: "On, Red-eye reduction"
  of 0x4d: "On, Red-eye reduction, Return not detected"
  of 0x4f: "On, Red-eye reduction, Return detected"
  of 0x50: "Off, Red-eye reduction"
  of 0x58: "Auto, Did not fire, Red-eye reduction"
  of 0x59: "Auto, Fired, Red-eye reduction"
  of 0x5d: "Auto, Fired, Red-eye reduction, Return not detected"
  of 0x5f: "Auto, Fired, Red-eye reduction, Return detected"
  else: "Unknown (" & $val & ")"
