# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# UniImage — raster image engine for the lituus-lab Uni* family (Nim + C-ABI + Python).

version       = "1.0.0"
author        = "lituus-lab"
description   = "Raster image engine: core model, EXIF/XMP/IPTC metadata, codecs (Nim + C-ABI + Python)"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"
requires "https://github.com/lituus-lab/UniColor#main"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --path:src --index:on --outdir:pages/api --project --hints:off src/UniImage.nim"
  exec "nimble book"
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_core tests/test_core.nim"
  exec "nim c -r --path:src -o:build/test_exif tests/test_exif.nim"
  exec "nim c -r --path:src -o:build/test_formats tests/test_formats.nim"
  exec "nim c -r --path:src -o:build/test_heif tests/test_heif.nim"
  exec "nim c -r --path:src -o:build/test_webp tests/test_webp.nim"
  exec "nim c -r --path:src -o:build/test_tiff tests/test_tiff.nim"
  exec "nim c -r --path:src -o:build/test_thumbnail tests/test_thumbnail.nim"
  exec "nim c -r --path:src -o:build/test_compress tests/test_compress.nim"
  exec "nim c -r --path:src -o:build/test_encode tests/test_encode.nim"
  exec "nim c -r --path:src -o:build/test_process tests/test_process.nim"
  exec "nim c -r --path:src -o:build/test_quantize tests/test_quantize.nim"
  exec "nim c -r --path:src -o:build/test_metadata tests/test_metadata.nim"

task testRelease, "Nim tests (-d:release: contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_core_rel tests/test_core.nim"
  exec "nim c -r -d:release --path:src -o:build/test_exif_rel tests/test_exif.nim"
  exec "nim c -r -d:release --path:src -o:build/test_formats_rel tests/test_formats.nim"
  exec "nim c -r -d:release --path:src -o:build/test_heif_rel tests/test_heif.nim"
  exec "nim c -r -d:release --path:src -o:build/test_webp_rel tests/test_webp.nim"
  exec "nim c -r -d:release --path:src -o:build/test_tiff_rel tests/test_tiff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_thumbnail_rel tests/test_thumbnail.nim"
  exec "nim c -r -d:release --path:src -o:build/test_compress_rel tests/test_compress.nim"
  exec "nim c -r -d:release --path:src -o:build/test_encode_rel tests/test_encode.nim"
  exec "nim c -r -d:release --path:src -o:build/test_process_rel tests/test_process.nim"
  exec "nim c -r -d:release --path:src -o:build/test_quantize_rel tests/test_quantize.nim"
  exec "nim c -r -d:release --path:src -o:build/test_metadata_rel tests/test_metadata.nim"

task testCi, "Nim tests (CI subset, debug)":
  exec "nimble test"

task testCiRelease, "Nim tests (CI subset, -d:release)":
  exec "nimble testRelease"

task testAll, "debug + release + C ABI":
  exec "nimble test"
  exec "nimble testRelease"
  exec "nimble ctest"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"

task benchmarkComposite, "Benchmark deterministic RGBA compositing":
  exec "nim c -r -d:release --path:src -o:build/benchmark_composite" &
       " benchmarks/benchmark_composite.nim"

task benchmarkCompositeBaseline, "Run and aggregate three composite benchmarks":
  exec "nim c -d:release --path:src -o:build/benchmark_composite" &
       " benchmarks/benchmark_composite.nim"
  exec "nim c -r -d:release -o:build/run_composite_baseline" &
       " benchmarks/run_composite_baseline.nim"

task benchmarkResizeAlpha, "Benchmark alpha-correct weighted resizing":
  exec "nim c -r -d:release --mm:orc --path:src" &
       " -o:build/benchmark_resize_alpha benchmarks/benchmark_resize_alpha.nim"

task benchmarkResizeAlphaBaseline, "Aggregate three alpha-resize benchmarks":
  exec "nim c -d:release --mm:orc --path:src" &
       " -o:build/benchmark_resize_alpha benchmarks/benchmark_resize_alpha.nim"
  exec "nim c -r -d:release --mm:orc" &
       " -o:build/run_resize_alpha_baseline" &
       " benchmarks/run_resize_alpha_baseline.nim"

task uniimg, "Build the uniimg CLI (metadata inspect/strip; codec convert)":
  exec "nim c --path:src -o:bin/uniimg bin/uniimg.nim"

# Nim takes `-o:` literally and appends no platform extension.
const
  sharedLib =
    when defined(windows): "libUniImage.dll"
    elif defined(macosx): "libUniImage.dylib"
    else: "libUniImage.so"
  staticLib = "libUniImage.a"  # MinGW `ar` on Windows, so `.a` everywhere.

  # @rpath install_name, so the copy bundled in the wheel is found at import.
  macArgs =
    when defined(macosx): " --passL:\"-Wl,-install_name,@rpath/" & sharedLib & "\""
    else: ""

task clib, "C shared library":
  # -d:release (not -d:danger): the C ABI parses untrusted image bytes, so Nim's
  # bounds/overflow checks are kept as a defense-in-depth backstop. Every ui_exif_*
  # entry point also validates handles/lengths itself and traps CatchableError +
  # Defect at the boundary.
  exec "nim c --path:src --app:lib --noMain --mm:arc -d:release -o:" & sharedLib & macArgs &
       " src/UniImage/c_api.nim"

task clibStatic, "C static library":
  exec "nim c --path:src --app:staticlib --noMain --mm:arc -d:release -o:" & staticLib &
       " src/UniImage/c_api.nim"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --path:src --cc:vcc --app:staticlib --noMain --mm:arc -d:release" &
       " -o:UniImage.lib src/UniImage/c_api.nim"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec "nimble clibStatic"
  exec makeExe & " -C tests/c"

task cexample, "C demo":
  exec "nimble clibStatic"
  exec makeExe & " -C examples/c"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec "nimble clibMsvc"
  else:
    exec "nimble clib"

task pyNotebookDeps, "Install notebook build deps (nbformat, nbclient, ipykernel) if missing":
  exec "python3 -m pip install --break-system-packages --quiet nbformat nbclient ipykernel"

task buildCython, "Cython extension in-place":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  # nimscript `cd` (lib/system/nimscript.nim) changes the VM cwd for the next
  # exec without a shell, so the task works under nimble's no-shell exec on Windows.
  cd "py"
  exec "python3 setup.py build_ext --inplace"
  cd ".."

task pyTest, "Cython extension + pytest":
  exec "nimble buildCython"
  cd "py"
  exec "python3 -m pytest -q"
  cd ".."

task pyWheel, "wheel":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  cd "py"
  exec "python3 setup.py bdist_wheel"
  cd ".."

task pySdist, "Python source distribution with vendored Nim source":
  exec "nimble pyDeps"
  cd "py"
  exec "python3 setup.py sdist"
  cd ".."

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out. Nim 2.2 can still emit counters for a synthetic
  # line past EOF and empty counters for imported platform modules; ignore only
  # those two lcov mapping categories, never source/read/write errors.
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  # One executable keeps each generated module and its counters in one graph.
  # Merging separately compiled Nim modules is ambiguous because their module
  # initializers can receive different source lines in each executable.
  exec "nim c --path:src --nimcache:" & cache &
       " --debugger:native --passC:--coverage --passL:--coverage" &
       " -o:build/test_coverage tests/test_coverage.nim"
  exec "./build/test_coverage"
  exec "lcov --capture --directory " & cache & " --base-directory ." &
       " --include \"*/src/UniImage/*\" --output-file lcov.info --quiet" &
       " --ignore-errors gcov,gcov"
  exec "genhtml lcov.info --output-directory coverage --legend --quiet" &
       " --ignore-errors range,range"
  exec "lcov --summary lcov.info"

# Opt-in, macOS only: builds the system HEIC/AVIF decoder and runs the suite
# that exercises it. Not in the default gate, because the default build links
# no framework and must keep running anywhere.
task testApple, "Nim tests with the macOS system codecs (-d:appleCodecs)":
  exec "nim c -r -d:appleCodecs --path:src -o:build/test_heif_apple tests/test_heif.nim"
