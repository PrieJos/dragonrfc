#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Type stub for the compiled ``dragonrfc._core`` module.

Public typing contract of the Cython extension; it must match ``_core.pyx``
(checked by ``task stubtest``).

API:
    - ``RFCValue``: typing-only alias for values returned by function calls.
    - :class:`RFCClient`: client connection to an SAP system, with function
      calls, metadata lookups and batch prefetch.
    - :class:`Repository`: SDK metadata cache of one system ID.
    - :func:`sdk_version`: version of the loaded SDK.
    - ``_roundtrip``, ``_describe_test``, ``_add_test_repository``: private
      test hooks.

Example:
    >>> from dragonrfc import RFCClient
    >>> with RFCClient(dest="MYSYS") as conn:
    ...     conn.ping()
"""

import datetime
import os
from collections.abc import Iterable
from decimal import Decimal
from types import TracebackType
from typing import Self, TypeAlias

from typing_extensions import disjoint_base

from dragonrfc.metadata import FunctionMetadata, TypeMetadata

RFCValue: TypeAlias = (
    str
    | int
    | float
    | Decimal
    | datetime.date
    | datetime.time
    | bytes
    | dict[str, RFCValue]
    | list[dict[str, RFCValue]]
    | None
)

def _roundtrip(
    fields: list[tuple[str, int, int, int, int]], values: dict[str, object]
) -> dict[str, RFCValue]:
    """Sets values into a locally defined function and reads them back.

    Test hook: exercises the conversions against real SDK containers without
    an SAP system.

    Args:
        fields: ``(name, rfctype, nuc_length, uc_length, decimals)`` per field.
        values: Parameter values to set, by field name.

    Returns:
        All parameters read back from the function container.
    """

def _describe_test(
    fields: list[tuple[str, int, int, int, int]],
) -> FunctionMetadata:
    """Describes the function that ``_roundtrip`` builds from ``fields``.

    Test hook: exercises the metadata readers without an SAP system.
    """

def _add_test_repository(
    sysid: str, fields: list[tuple[str, int, int, int, int]]
) -> None:
    """Adds the ``_roundtrip`` function and its line type to ``sysid``'s cache.

    Test hook: exercises :class:`Repository` without an SAP system. The cache
    owns the descriptions afterwards; drop them with ``Repository.clear``.
    """

def sdk_version() -> tuple[int, int, int]:
    """Returns the version of the loaded SAP NW RFC SDK.

    Returns:
        ``(major, minor, patch_level)``, e.g. ``(7500, 0, 20)``.

    Example:
        >>> sdk_version()
        (7500, 0, 20)
    """

@disjoint_base
class Repository:
    """The SDK metadata cache of one SAP system.

    The SDK keeps one process-wide cache per system ID. It is filled by
    :meth:`RFCClient.call`, :meth:`RFCClient.describe_function`,
    :meth:`RFCClient.prefetch` or :meth:`load`, and read here without a
    connection.

    Example:
        >>> repo = conn.repository  # or Repository("ABC")
        >>> repo.save("abc-metadata.json")
        >>> Repository("ABC").load("abc-metadata.json")  # at the next start-up
    """

    def __init__(self, sysid: str | None = None) -> None:
        """Selects the cache of a system.

        Args:
            sysid: SAP system ID, e.g. ``"ABC"``, or ``None`` for the SDK's
                default repository.

        Raises:
            TypeError: If ``sysid`` is neither ``str`` nor ``None``.
        """
    @property
    def sysid(self) -> str | None:
        """System ID of this cache, or ``None`` for the default repository."""
    def describe_function(self, name: str) -> FunctionMetadata:
        """Returns the cached signature of a function module.

        Args:
            name: Function module name, e.g. ``"STFC_CONNECTION"``.

        Returns:
            Parameters, with nested structure types, and classic exceptions.

        Raises:
            RFCError: If the function is not in this cache.
        """
    def describe_type(self, name: str) -> TypeMetadata:
        """Returns the cached layout of a DDIC structure or table type.

        Args:
            name: Type name, e.g. ``"RFCTEST"``.

        Returns:
            Fields with offsets and lengths, with nested types.

        Raises:
            RFCError: If the type is not in this cache.
        """
    def evict_function(self, name: str) -> None:
        """Drops a function description from this cache.

        Use it after the function's signature changed in the backend; the next
        call or description reads it again from the DDIC.

        Args:
            name: Function module name.

        Raises:
            RFCError: If the SDK rejects the removal.
        """
    def evict_type(self, name: str) -> None:
        """Drops a type description from this cache.

        Args:
            name: DDIC structure or table type name.

        Raises:
            RFCError: If the SDK rejects the removal.
        """
    def clear(self) -> None:
        """Drops every description in this cache.

        Raises:
            RFCError: If the SDK rejects the request.
        """
    def save(self, path: str | os.PathLike[str]) -> None:
        """Writes the cached function descriptions to a JSON file.

        The file format is shared with SAP JCo and SAP NCo. Load it with
        :meth:`load` to skip DDIC lookups at start-up.

        Args:
            path: Target file; created or overwritten.

        Raises:
            OSError: If the file cannot be written.
            RFCError: If the SDK fails to serialize the cache.
        """
    def load(self, path: str | os.PathLike[str]) -> None:
        """Replaces this cache with the descriptions in a JSON file.

        The file must match the backend's current DDIC; outdated metadata can
        truncate or corrupt data in later calls. The format keeps layouts but
        not parameter defaults or texts, and the SDK drops blanks from loaded
        exception messages.

        Args:
            path: File written by :meth:`save`, SAP JCo or SAP NCo.

        Raises:
            OSError: If the file cannot be read.
            RFCError: If the file is not a valid repository.
        """

@disjoint_base
class RFCClient:
    """Client connection to an SAP system.

    The connection is opened on construction and closed by :meth:`close`, by
    leaving a ``with`` block, or, as a last resort, when the object is collected.

    Example:
        >>> with RFCClient(
        ...     ashost="host", sysnr="00", client="100", user="me", passwd="secret"
        ... ) as conn:
        ...     conn.call("STFC_CONNECTION", REQUTEXT="hello")["ECHOTEXT"]
        'hello'
    """

    def __init__(self, **params: str) -> None:
        """Opens the connection.

        Args:
            **params: SDK logon parameters such as ``ashost``, ``sysnr``,
                ``client``, ``user``, ``passwd``, ``dest`` or ``wshost``. For
                SNC, replace ``user``/``passwd`` with ``snc_mode``,
                ``snc_qop``, ``snc_myname``, ``snc_partnername`` and
                optionally ``snc_lib``; ``mysapsso2`` and ``x509cert`` log
                on with a ticket or certificate. See ``sapnwrfc.ini`` in the
                SDK for the full list. Values must be ``str``.

        Raises:
            ValueError: If no parameters are given.
            TypeError: If a value is not a ``str``.
            RFCLogonError: If the logon is rejected.
            RFCCommunicationError: If the system cannot be reached.
        """
    def __enter__(self) -> Self:
        """Returns the connection itself for use in a ``with`` block."""
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Closes the connection when leaving the ``with`` block."""
    @property
    def alive(self) -> bool:
        """Whether the connection handle is open and valid."""
    def close(self) -> None:
        """Closes the connection. Calling it again has no effect.

        Raises:
            RFCError: If the SDK fails to close the connection.
        """
    def ping(self) -> None:
        """Sends a ping to the SAP system.

        Raises:
            RFCCommunicationError: If the system does not answer.
            RFCExternalRuntimeError: If the connection is closed.
        """
    def call(self, name: str, **params: object) -> dict[str, RFCValue]:
        """Invokes a remote-enabled function module.

        Args:
            name: Function module name, e.g. ``"STFC_CONNECTION"``.
            **params: Importing, changing and table parameters. Structures are
                mappings and tables are sequences of mappings.

        Returns:
            Exporting, changing and table parameters returned by the system.

        Raises:
            TypeError: If a value does not fit the ABAP type of its parameter.
            RFCABAPApplicationError: If the function raises an ABAP exception.
            RFCABAPRuntimeError: On ABAP runtime errors or messages.
            RFCCommunicationError: If the network call fails.
            RFCExternalRuntimeError: On unknown parameters or conversion errors.
        """
    def describe_function(self, name: str) -> FunctionMetadata:
        """Returns the signature of a function module.

        The description comes from the SDK cache for this system, or from the
        system's DDIC on first use.

        Args:
            name: Function module name, e.g. ``"STFC_CONNECTION"``.

        Returns:
            Parameters, with nested structure types, and classic exceptions.

        Raises:
            RFCError: If the function module does not exist.
            RFCCommunicationError: If the network call fails.
            RFCExternalRuntimeError: If the connection is closed.
        """
    def describe_type(self, name: str) -> TypeMetadata:
        """Returns the layout of a DDIC structure or table type.

        Args:
            name: Type name, e.g. ``"RFCTEST"``.

        Returns:
            Fields with offsets and lengths, with nested types.

        Raises:
            RFCError: If the type does not exist.
            RFCCommunicationError: If the network call fails.
            RFCExternalRuntimeError: If the connection is closed.
        """
    def prefetch(
        self,
        functions: Iterable[str] = (),
        types: Iterable[str] = (),
    ) -> dict[str, str]:
        """Loads many descriptions into the SDK cache in one request.

        Open the connection with ``USE_REPOSITORY_ROUNDTRIP_OPTIMIZATION="1"``
        so the SDK fetches everything in a single roundtrip; the backend needs
        the support package level from SAP Note 1456826. Descriptions found are
        cached for :meth:`call`, :meth:`describe_function` and
        :attr:`repository`.

        Args:
            functions: Function module names.
            types: DDIC structure or table type names.

        Returns:
            Error message by name for every lookup that failed; empty when all
            succeeded. A function and a type with the same name share one key.

        Raises:
            TypeError: If ``functions`` or ``types`` is a ``str`` or holds a
                non-``str``.
            RFCCommunicationError: If the network call fails.
            RFCExternalRuntimeError: If the connection is closed.
        """
    @property
    def repository(self) -> Repository:
        """The SDK metadata cache of this connection's system.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
        """
    def evict_function(self, name: str) -> None:
        """Drops a function description from the SDK cache for this system.

        Use it after the function's signature changed in the backend; the next
        call or description reads it again from the DDIC.

        Args:
            name: Function module name.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
            RFCError: If the SDK rejects the removal.
        """
    def evict_type(self, name: str) -> None:
        """Drops a type description from the SDK cache for this system.

        Args:
            name: DDIC structure or table type name.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
            RFCError: If the SDK rejects the removal.
        """
