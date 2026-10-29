#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Typed Python bindings for the SAP NetWeaver RFC SDK.

The SDK itself is not bundled: install it and set ``SAPNWRFC_HOME`` (Windows)
or make its ``lib/`` directory findable by the dynamic loader (Linux, macOS).

API:
    - :class:`RFCClient`: client connection; ``ping``, ``call``, ``close``,
      ``describe_function``, ``describe_type``, ``prefetch``, ``repository``,
      ``evict_function``, ``evict_type``.
    - :class:`Repository`: SDK metadata cache of one system; cache-only
      lookups, eviction, ``clear``, ``save`` and ``load`` (JSON file).
    - :class:`FunctionMetadata` and related dataclasses, :class:`ABAPType`,
      :class:`Direction`: function and type metadata.
    - :func:`sdk_version`: version of the loaded SDK.
    - :class:`RFCError` and its subclasses, one per SDK error group.
    - :class:`ReturnCode`, :class:`ErrorGroup`: SDK error enums.
    - ``__version__``: installed dragonrfc version.

Example:
    >>> import dragonrfc
    >>> with dragonrfc.RFCClient(dest="MYSYS") as conn:
    ...     conn.ping()
"""

import os
import sys
from importlib.metadata import version

if sys.platform == "win32" and "SAPNWRFC_HOME" in os.environ:
    # Kept referenced: the directory is removed from the search path on close.
    _dll_dir = os.add_dll_directory(os.path.join(os.environ["SAPNWRFC_HOME"], "lib"))

from dragonrfc._core import Repository, RFCClient, sdk_version
from dragonrfc.exceptions import (
    ErrorGroup,
    ReturnCode,
    RFCABAPApplicationError,
    RFCABAPRuntimeError,
    RFCCommunicationError,
    RFCCryptoLibError,
    RFCError,
    RFCExternalApplicationError,
    RFCExternalAuthenticationError,
    RFCExternalAuthorizationError,
    RFCExternalRuntimeError,
    RFCLockingError,
    RFCLogonError,
)
from dragonrfc.metadata import (
    ABAPType,
    Direction,
    ExceptionMetadata,
    FieldMetadata,
    FunctionMetadata,
    ParameterMetadata,
    TypeMetadata,
)

__version__ = version("dragonrfc")

__all__ = [
    "ABAPType",
    "Direction",
    "ErrorGroup",
    "ExceptionMetadata",
    "FieldMetadata",
    "FunctionMetadata",
    "ParameterMetadata",
    "RFCABAPApplicationError",
    "RFCABAPRuntimeError",
    "RFCClient",
    "RFCCommunicationError",
    "RFCCryptoLibError",
    "RFCError",
    "RFCExternalApplicationError",
    "RFCExternalAuthenticationError",
    "RFCExternalAuthorizationError",
    "RFCExternalRuntimeError",
    "RFCLockingError",
    "RFCLogonError",
    "Repository",
    "ReturnCode",
    "TypeMetadata",
    "__version__",
    "sdk_version",
]
