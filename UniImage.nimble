# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# UniImage — raster image engine for the lituus-lab Uni* family (Nim + C-ABI + Python).

version       = "1.1.0"
author        = "lituus-lab"
description   = "Raster image engine: core model, EXIF/XMP/IPTC metadata, codecs (Nim + C-ABI + Python)"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"
requires "https://github.com/lituus-lab/UniColor#main"
requires "https://github.com/lituus-lab/UniChecksum#main"
# Container framing: the box layer HEIF and the Exif item inside an MP4 are
# read through, shared with the video and audio libraries that read the same
# structure.
requires "https://github.com/lituus-lab/UniContainer#main"
requires "https://github.com/lituus-lab/UniCompress#main"

# nimble 0.22 exits 0 even when an `exec` inside a task fails, so a task's exit
# code says nothing about whether its body ran. Each task writes a marker as
# its last statement; `tools/gate.nim` removes the marker, runs the task, and
# fails if it is not there afterwards. `nimble canary` proves the gate still
# bites -- if that one ever passes, every other green result is worthless.
const gateExe =
  when defined(windows): "build/unigate.exe" else: "build/unigate"

template done(task: string) =
  mkDir "build/.gate"
  writeFile("build/.gate/" & task & ".ok", "")

proc gate(task: string): string =
  ## `exec gate("test")` -- builds the tool on first use.
  if not fileExists(gateExe):
    exec "nim c --hints:off -o:" & gateExe & " tools/gate.nim"
  gateExe & " " & task

task canary, "Must fail: proves the gate still catches a broken build":
  # No `done` here on purpose: the exec below raises, so the marker is never
  # written and the gate reports the failure nimble swallowed.
  exec "nim c -r --hints:off --path:src -o:build/canary tests/canary_broken.nim"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"
  done "lint"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"
  done "checkVGraph"

const bookDeps = [
  "https://github.com/pietroppeter/nimib#v0.4.1",
  "https://github.com/pietroppeter/nimibook#v0.4.0",
  "https://github.com/lituus-lab/lituus-theme#v0.2.0",
]
taskRequires "docsDeps", bookDeps[0], bookDeps[1], bookDeps[2]
taskRequires "book", bookDeps[0], bookDeps[1], bookDeps[2]
taskRequires "docs", bookDeps[0], bookDeps[1], bookDeps[2]

task docsDeps, "Install the docs toolchain (nimib + nimibook + theme)":
  echo "nimib, nimibook and lituus-theme installed."
  done "docsDeps"

task bookInit, "Scaffold a chapter added to the table of contents":
  withDir "book":
    exec "nim c -r --hints:off -o:../build/nbook nbook.nim init"
  done "bookInit"

task book, "Build the multi-chapter book (needs nimib + nimibook)":
  withDir "book":
    exec "nim c -r --hints:off -o:../build/nbook nbook.nim clean"
    # `init` before `build`, on every run: it is what creates `__site/assets`,
    # which is not tracked, so a fresh clone has none and every page ships
    # referencing a stylesheet and a script that are not there.
    exec "nim c -r --hints:off -o:../build/nbook nbook.nim init"
    exec "nim c -r --hints:off -o:../build/nbook nbook.nim build"
  done "book"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec gate("book")
  cpDir "book/__site", "pages"
  rmFile "pages/book.json"
  # `--path:src` is not optional. Without it `import UniImage/core` inside the
  # umbrella does not resolve against this checkout -- `UniImage/` is under
  # `src/`, not at the root -- so Nim falls through to the nimble path and
  # documents whatever version happens to be installed there.
  exec "nim doc --index:on --outdir:pages/api --project --hints:off " &
       "--path:src src/UniImage.nim"
  # ...and the reference wears the same theme. `nim doc` has no stylesheet
  # option, so the palette is appended to the one it just wrote.
  exec "nim c -r --hints:off --outdir:build tools/theme_api.nim " &
       "pages/api/nimdoc.out.css"
  done "docs"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_core tests/test_core.nim"
  exec "nim c -r --path:src -o:build/test_version tests/test_version.nim"
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
  done "test"

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
  done "testRelease"

task testCi, "Nim tests (CI subset, debug)":
  exec gate("test")
  done "testCi"

task testCiRelease, "Nim tests (CI subset, -d:release)":
  exec gate("testRelease")
  done "testCiRelease"

task testAll, "debug + release + C ABI":
  exec gate("test")
  exec gate("testRelease")
  exec gate("ctest")
  done "testAll"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"
  done "example"

task benchmarkComposite, "Benchmark deterministic RGBA compositing":
  exec "nim c -r -d:release --path:src -o:build/benchmark_composite" &
       " benchmarks/benchmark_composite.nim"
  done "benchmarkComposite"

task benchmarkCompositeBaseline, "Run and aggregate three composite benchmarks":
  exec "nim c -d:release --path:src -o:build/benchmark_composite" &
       " benchmarks/benchmark_composite.nim"
  exec "nim c -r -d:release -o:build/run_composite_baseline" &
       " benchmarks/run_composite_baseline.nim"
  done "benchmarkCompositeBaseline"

task benchmarkResizeAlpha, "Benchmark alpha-correct weighted resizing":
  exec "nim c -r -d:release --mm:orc --path:src" &
       " -o:build/benchmark_resize_alpha benchmarks/benchmark_resize_alpha.nim"
  done "benchmarkResizeAlpha"

task benchmarkResizeAlphaBaseline, "Aggregate three alpha-resize benchmarks":
  exec "nim c -d:release --mm:orc --path:src" &
       " -o:build/benchmark_resize_alpha benchmarks/benchmark_resize_alpha.nim"
  exec "nim c -r -d:release --mm:orc" &
       " -o:build/run_resize_alpha_baseline" &
       " benchmarks/run_resize_alpha_baseline.nim"
  done "benchmarkResizeAlphaBaseline"

task uniimg, "Build the uniimg CLI (metadata inspect/strip; codec convert)":
  exec "nim c --path:src -o:bin/uniimg bin/uniimg.nim"
  done "uniimg"

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
  done "clib"

task clibStatic, "C static library":
  exec "nim c --path:src --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release -o:" & staticLib &
       " src/UniImage/c_api.nim"
  done "clibStatic"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --path:src --cc:vcc --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release" &
       " -o:UniImage.lib src/UniImage/c_api.nim"
  done "clibMsvc"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec gate("clibStatic")
  exec makeExe & " -C tests/c"
  done "ctest"

task cexample, "C demo":
  exec gate("clibStatic")
  exec makeExe & " -C examples/c"
  done "cexample"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"
  # Ubuntu ships a setuptools that predates PEP 639 and cannot parse the SPDX
  # licence pyproject.toml declares. pip refuses to uninstall a distro- or
  # brew-managed package, so install over it rather than --upgrade it.
  # packaging comes with it: setuptools 77 reads packaging.licenses, which the
  # distro's older copy does not have, and it shadows the vendored one.
  exec "python3 -m pip install --break-system-packages --quiet --ignore-installed \"setuptools>=77\" \"packaging>=24.2\""
  done "pyDeps"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec gate("clibMsvc")
  else:
    exec gate("clib")
  done "pyLib"

task pyNotebookDeps, "Install notebook build deps (nbformat, nbclient, ipykernel) if missing":
  exec "python3 -m pip install --break-system-packages --quiet nbformat nbclient ipykernel"
  done "pyNotebookDeps"

task buildCython, "Cython extension in-place":
  exec gate("pyLib")
  exec gate("pyDeps")
  # nimscript `cd` (lib/system/nimscript.nim) changes the VM cwd for the next
  # exec without a shell, so the task works under nimble's no-shell exec on Windows.
  cd "py"
  exec "python3 setup.py build_ext --inplace"
  cd ".."
  done "buildCython"

task pyTest, "Cython extension + pytest":
  exec gate("buildCython")
  cd "py"
  exec "python3 -m pytest -q"
  cd ".."
  done "pyTest"

task pyWheel, "wheel":
  exec gate("pyLib")
  exec gate("pyDeps")
  cd "py"
  exec "python3 setup.py bdist_wheel"
  cd ".."
  done "pyWheel"

task pySdist, "Python source distribution with vendored Nim source":
  exec gate("pyDeps")
  cd "py"
  exec "python3 setup.py sdist"
  cd ".."
  done "pySdist"

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
       " --include \"*/src/UniImage/*\" --output-file lcov.info --quiet --ignore-errors mismatch" &
       " --ignore-errors gcov,gcov"
  # gcov can attribute a final generated expression to EOF + 1, and that one
  # artefact answers to two names: lcov 2.0, the version ubuntu-latest installs,
  # calls it `unmapped` and rejects `range` as a category outright, while 2.5
  # calls it `range` and can filter those lines away. Ask which one is there
  # rather than assume; both were measured.
  let genhtmlRange =
    if gorgeEx("genhtml --version").output.contains("LCOV version 2.0"):
      " --ignore-errors unmapped"
    else: " --filter range --ignore-errors range"
  exec "genhtml lcov.info" & genhtmlRange &
       " --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
  done "coverage"

# Opt-in, macOS only: builds the system HEIC/AVIF decoder and runs the suite
# that exercises it. Not in the default gate, because the default build links
# no framework and must keep running anywhere.
task testApple, "Nim tests with the macOS system codecs (-d:appleCodecs)":
  exec "nim c -r -d:appleCodecs --path:src -o:build/test_heif_apple tests/test_heif.nim"
  done "testApple"
