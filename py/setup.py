# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Build uniimage._core, a Cython extension over the UniImage C ABI.

In a repository checkout, run ``nimble pyLib`` before invoking setup.py. A
source distribution carries the Nim project under ``_nimsrc`` and builds the
native library with nimble; installing it therefore requires Nim on PATH.
"""
import os
import shutil
import subprocess
import sys

from setuptools import Extension, setup
from Cython.Build import cythonize

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INCLUDE = os.path.join(ROOT, "include")
PKG_DIR = os.path.join(HERE, "uniimage")
VENDOR_DIR = os.path.join(HERE, "_nimsrc")
NIMBLE_FILE = "UniImage.nimble"
VENDOR_FILES = [NIMBLE_FILE, "config.nims"]
VENDOR_DIRS = ["src", "include"]

# Windows: link a vcc static lib, since MSVC CPython cannot link MinGW output.
# Elsewhere: bundle the shared lib in the package, found through an rpath
# relative to the extension. macOS rejects distutils' -R, hence extra_link_args.
if sys.platform == "win32":
    LIB_NAME, BUNDLED = "UniImage.lib", False
    LINK_ARGS, NIMBLE_TASK = [], "clibMsvc"
elif sys.platform == "darwin":
    LIB_NAME, BUNDLED = "libUniImage.dylib", True
    LINK_ARGS, NIMBLE_TASK = ["-Wl,-rpath,@loader_path"], "clib"
else:
    LIB_NAME, BUNDLED = "libUniImage.so", True
    LINK_ARGS, NIMBLE_TASK = ["-Wl,-rpath,$ORIGIN"], "clib"


def vendor_nim_source():
    """Copy the Nim project below py/ so setuptools can include it."""
    if os.path.exists(VENDOR_DIR):
        shutil.rmtree(VENDOR_DIR)
    os.makedirs(VENDOR_DIR)
    for filename in VENDOR_FILES:
        shutil.copy2(os.path.join(ROOT, filename), os.path.join(VENDOR_DIR, filename))
    for dirname in VENDOR_DIRS:
        shutil.copytree(os.path.join(ROOT, dirname), os.path.join(VENDOR_DIR, dirname))


def nim_project_dir():
    """Return the checkout root or the project vendored in an sdist."""
    if os.path.exists(os.path.join(ROOT, NIMBLE_FILE)):
        return ROOT
    if os.path.exists(os.path.join(VENDOR_DIR, NIMBLE_FILE)):
        return VENDOR_DIR
    return None


def ensure_lib_built():
    """Return the native library, building it for an extracted sdist."""
    prebuilt = os.path.join(ROOT, LIB_NAME)
    if os.path.exists(prebuilt):
        return prebuilt
    project = nim_project_dir()
    if project is None:
        raise SystemExit(
            f"setup.py: {prebuilt} not found — run `nimble {NIMBLE_TASK}` first."
        )
    built = os.path.join(project, LIB_NAME)
    if os.path.exists(built):
        return built
    try:
        subprocess.check_call(["nimble", "install", "-y"], cwd=project)
        subprocess.check_call(["nimble", NIMBLE_TASK], cwd=project)
    except FileNotFoundError as exc:
        raise SystemExit(
            "setup.py: building uniimage from source requires Nim and nimble on PATH."
        ) from exc
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"setup.py: `nimble {NIMBLE_TASK}` failed: {exc}") from exc
    if not os.path.exists(built):
        raise SystemExit(f"setup.py: native build did not produce {built}")
    return built


# `sdist` alone packages source and must not require a prebuilt library. A
# combined command such as `sdist bdist_wheel` still needs the native library.
commands = [argument for argument in sys.argv[1:] if not argument.startswith("-")]
if commands == ["sdist"]:
    vendor_nim_source()
    INCLUDE, LIB_DIR = os.path.join(ROOT, "include"), ROOT
else:
    lib_path = ensure_lib_built()
    LIB_DIR = os.path.dirname(lib_path)
    INCLUDE = os.path.join(ROOT, "include")
    if not os.path.isdir(INCLUDE):
        INCLUDE = os.path.join(VENDOR_DIR, "include")
    if BUNDLED:
        os.makedirs(PKG_DIR, exist_ok=True)
        shutil.copy2(lib_path, os.path.join(PKG_DIR, LIB_NAME))


pyx = os.path.join("uniimage", "_core.pyx")
ext = Extension(
    "uniimage._core",
    sources=[pyx if os.path.exists(os.path.join(HERE, pyx)) else
             os.path.join("uniimage", "_core.c")],
    include_dirs=[INCLUDE],
    library_dirs=[LIB_DIR],
    extra_link_args=LINK_ARGS,
    libraries=["UniImage"],
)
ext_modules = cythonize([ext], language_level=3) if ext.sources[0].endswith(".pyx") else [ext]

setup(
    ext_modules=ext_modules,
    include_package_data=True,
    package_data={"uniimage": [LIB_NAME] if BUNDLED else []},
    exclude_package_data={"uniimage": ["_core.c"]},
    zip_safe=False,
)
