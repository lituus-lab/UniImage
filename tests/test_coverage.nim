# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab

# These imports register and execute their unittest suites.
{.push warning[UnusedImport]: off.}
import test_core
import test_exif
import test_formats
import test_webp
import test_tiff
import test_compress
import test_encode
import test_process
import test_quantize
import test_thumbnail
import test_metadata
{.pop.}
