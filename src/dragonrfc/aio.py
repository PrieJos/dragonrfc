#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""asyncio interface to SAP systems.

The SDK has no non-blocking client API, so each awaitable runs the matching
:class:`RFCClient` method on a worker thread of the event loop's default
executor. The SDK call releases the GIL while it waits on the network: calls on
separate clients overlap, calls on one client run one at a time. Raise the
number of calls in flight beyond the default executor size with
``loop.set_default_executor``.

Cancelling a task that waits on the network aborts the remote call with
``RfcCancel``, which also closes the connection.

API:
    - :class:`AsyncRFCClient`: ``open``, ``call``, ``ping``,
      ``describe_function``, ``describe_type``, ``prefetch``, ``close``,
      ``alive``, ``client``; usable as an async context manager.

Example:
    >>> async with await AsyncRFCClient.open(dest="MYSYS") as conn:
    ...     (await conn.call("STFC_CONNECTION", REQUTEXT="hi"))["ECHOTEXT"]
    'hi'
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Iterable
from types import TracebackType
from typing import TYPE_CHECKING, ParamSpec, Self, TypeVar

from dragonrfc._core import RFCClient

if TYPE_CHECKING:
    from dragonrfc._core import RFCValue
    from dragonrfc.metadata import FunctionMetadata, TypeMetadata

_P = ParamSpec("_P")
_T = TypeVar("_T")


class AsyncRFCClient:
    """asyncio wrapper of an :class:`RFCClient`.

    Methods match :class:`RFCClient` and raise the same errors. Cache-only
    operations (``repository``, ``evict_function``, ``evict_type``) never
    block: use them through :attr:`client`.

    Example:
        >>> async with await AsyncRFCClient.open(dest="MYSYS") as conn:
        ...     await conn.ping()
    """

    def __init__(self, client: RFCClient) -> None:
        """Wraps an open client.

        Args:
            client: The connection to use; this object takes it over.
        """
        self._client = client
        self._lock = asyncio.Lock()

    @classmethod
    async def open(cls, **params: str) -> Self:
        """Opens a connection without blocking the event loop.

        Args:
            **params: SDK logon parameters, as for :class:`RFCClient`.

        Returns:
            The open client.

        Raises:
            ValueError: If no parameters are given.
            TypeError: If a value is not a ``str``.
            RFCLogonError: If the logon is rejected.
            RFCCommunicationError: If the system cannot be reached.
        """
        return cls(await asyncio.to_thread(RFCClient, **params))

    async def __aenter__(self) -> Self:
        """Returns the client itself for use in an ``async with`` block."""
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Closes the connection when leaving the ``async with`` block."""
        await self.close()

    def __repr__(self) -> str:
        """Returns whether the connection is open."""
        return f"<dragonrfc.AsyncRFCClient {'open' if self.alive else 'closed'}>"

    @property
    def client(self) -> RFCClient:
        """The wrapped synchronous client."""
        return self._client

    @property
    def alive(self) -> bool:
        """Whether the connection handle is open and valid."""
        return self._client.alive

    async def _run(
        self,
        method: Callable[_P, _T],
        /,
        *args: _P.args,
        **kwargs: _P.kwargs,
    ) -> _T:
        # One call in flight per client: a task cancelled while queued here
        # must not abort the call of another task.
        async with self._lock:
            try:
                return await asyncio.to_thread(method, *args, **kwargs)
            except asyncio.CancelledError:
                self._client.cancel()
                raise

    async def close(self) -> None:
        """Closes the connection, after the running call. Repeats are no-ops.

        Raises:
            RFCError: If the SDK fails to close the connection.
        """
        await self._run(self._client.close)

    async def ping(self) -> None:
        """Sends a ping to the SAP system.

        Raises:
            RFCCommunicationError: If the system does not answer.
            RFCExternalRuntimeError: If the connection is closed.
        """
        await self._run(self._client.ping)

    async def call(self, name: str, **params: object) -> dict[str, RFCValue]:
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
        return await self._run(self._client.call, name, **params)

    async def describe_function(self, name: str) -> FunctionMetadata:
        """Returns the signature of a function module.

        Args:
            name: Function module name, e.g. ``"STFC_CONNECTION"``.

        Returns:
            Parameters, with nested structure types, and classic exceptions.

        Raises:
            RFCError: If the function module does not exist.
            RFCCommunicationError: If the network call fails.
            RFCExternalRuntimeError: If the connection is closed.
        """
        return await self._run(self._client.describe_function, name)

    async def describe_type(self, name: str) -> TypeMetadata:
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
        return await self._run(self._client.describe_type, name)

    async def prefetch(
        self,
        functions: Iterable[str] = (),
        types: Iterable[str] = (),
    ) -> dict[str, str]:
        """Loads many descriptions into the SDK cache in one request.

        Args:
            functions: Function module names.
            types: DDIC structure or table type names.

        Returns:
            Error message by name for every lookup that failed; empty when all
            succeeded.

        Raises:
            TypeError: If ``functions`` or ``types`` is a ``str`` or holds a
                non-``str``.
            RFCCommunicationError: If the network call fails.
            RFCExternalRuntimeError: If the connection is closed.
        """
        return await self._run(self._client.prefetch, functions, types)
