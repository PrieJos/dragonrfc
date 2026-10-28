#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Build script for the dragonrfc Cython extension.

Compiles ``dragonrfc._core`` against the SAP NW RFC SDK. The SDK is located
through the ``SAPNWRFC_HOME`` environment variable, which must contain
``include/`` and ``lib/``; the build stops with a clear message otherwise.
Platform macros (``SAPonLIN``, ``SAPonNT``, ``SAPonDARW``, ``SAPwith64_BIT``) are
derived by ``sapucrfc.h`` from the compiler; only ``SAPwithUNICODE`` must be set
by the client.

API:
    - Extension ``dragonrfc._core`` built from ``src/dragonrfc/_core.pyx``,
      linked to ``sapnwrfc`` with a per-OS runtime library path.

Example:
    Invoked by the build backend, never directly::

        $ SAPNWRFC_HOME=/usr/local/nwrfcsdk task setup
"""

import os
import sys
from pathlib import Path

from Cython.Build import cythonize
from setuptools import Extension, setup


def _sdk_home() -> Path:
    home = os.environ.get("SAPNWRFC_HOME")
    if not home:
        sys.exit("SAPNWRFC_HOME is not set; point it to the SAP NW RFC SDK directory.")
    path = Path(home)
    for sub in ("include", "lib"):
        if not (path / sub).is_dir():
            sys.exit(f"SAPNWRFC_HOME={home} has no '{sub}/' directory.")
    return path


sdk = _sdk_home()
include_dir = str(sdk / "include")
lib_dir = str(sdk / "lib")

compile_args: list[str] = []
link_args: list[str] = []
runtime_dirs: list[str] = []
if sys.platform == "win32":
    compile_args = ["/W3"]
elif sys.platform == "darwin":
    link_args = [f"-Wl,-rpath,{lib_dir}"]
else:
    runtime_dirs = [lib_dir]

extension = Extension(
    "dragonrfc._core",
    sources=["src/dragonrfc/_core.pyx"],
    include_dirs=[include_dir],
    library_dirs=[lib_dir],
    libraries=["sapnwrfc"],
    runtime_library_dirs=runtime_dirs,
    define_macros=[("SAPwithUNICODE", None), ("NDEBUG", None)],
    extra_compile_args=compile_args,
    extra_link_args=link_args,
)

setup(
    ext_modules=cythonize(
        [extension],
        compiler_directives={"language_level": 3, "embedsignature": True},
    ),
)
