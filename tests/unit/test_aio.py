#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Unit tests for :mod:`dragonrfc.aio`, without an SAP system.

A fake client stands in for :class:`RFCClient` at the SDK boundary; its
methods block on ``threading`` primitives to observe threads, overlap and
cancellation.

API:
    - ``FakeClient``: records calls; ``call`` runs an optional ``block`` hook.
    - Tests for delegation, worker threads, overlap across clients,
      cancellation of running and queued calls, ``async with`` and ``open``.

Example:
    $ task test
"""

import asyncio
import threading
from collections.abc import Callable
from typing import cast

import pytest

import dragonrfc
from dragonrfc import AsyncRFCClient, FunctionMetadata, RFCClient, TypeMetadata

TIMEOUT = 5
FUNCTION = FunctionMetadata(name="F", parameters=(), exceptions=())
TYPE = TypeMetadata(name="T", nuc_length=0, uc_length=0, fields=())


class FakeClient:
    def __init__(self, block: Callable[[], object] | None = None) -> None:
        self.block = block
        self.calls: list[tuple[str, tuple[object, ...], dict[str, object]]] = []
        self.threads: set[int] = set()
        self.cancelled = 0
        self.alive = True

    def _record(self, method: str, *args: object, **kwargs: object) -> None:
        self.calls.append((method, args, kwargs))
        self.threads.add(threading.get_ident())

    def call(self, name: str, **params: object) -> dict[str, object]:
        self._record("call", name, **params)
        if self.block:
            self.block()
        return {"ECHOTEXT": params.get("REQUTEXT")}

    def ping(self) -> None:
        self._record("ping")

    def describe_function(self, name: str) -> FunctionMetadata:
        self._record("describe_function", name)
        return FUNCTION

    def describe_type(self, name: str) -> TypeMetadata:
        self._record("describe_type", name)
        return TYPE

    def prefetch(self, functions: object, types: object) -> dict[str, str]:
        self._record("prefetch", functions, types)
        return {}

    def close(self) -> None:
        self._record("close")
        self.alive = False

    def cancel(self) -> None:
        self.cancelled += 1


def wrap(fake: FakeClient) -> AsyncRFCClient:
    return AsyncRFCClient(cast(RFCClient, fake))


def test_methods_delegate_on_a_worker_thread() -> None:
    fake = FakeClient()

    async def main() -> None:
        async with wrap(fake) as conn:
            assert repr(conn) == "<dragonrfc.AsyncRFCClient open>"
            assert conn.client is cast(RFCClient, fake)
            assert await conn.call("STFC_CONNECTION", REQUTEXT="hi") == {
                "ECHOTEXT": "hi",
            }
            await conn.ping()
            assert await conn.describe_function("F") is FUNCTION
            assert await conn.describe_type("T") is TYPE
            assert await conn.prefetch(["F"], ["T"]) == {}
        assert not conn.alive

    asyncio.run(main())
    assert [c[0] for c in fake.calls] == [
        "call",
        "ping",
        "describe_function",
        "describe_type",
        "prefetch",
        "close",
    ]
    assert fake.calls[0] == ("call", ("STFC_CONNECTION",), {"REQUTEXT": "hi"})
    assert fake.calls[4] == ("prefetch", (["F"], ["T"]), {})
    assert threading.get_ident() not in fake.threads


def test_loop_stays_responsive_during_a_call() -> None:
    release = threading.Event()
    fake = FakeClient(block=lambda: release.wait(TIMEOUT))

    async def main() -> None:
        task = asyncio.create_task(wrap(fake).call("F"))
        await asyncio.sleep(0.01)  # runs only if the call does not block the loop
        release.set()
        await task

    asyncio.run(main())
    assert release.is_set()


def test_calls_on_separate_clients_overlap() -> None:
    # Both calls pass the barrier only if they run at the same time.
    barrier = threading.Barrier(2, timeout=TIMEOUT)
    fakes = [FakeClient(block=barrier.wait) for _ in range(2)]

    async def main() -> None:
        await asyncio.gather(*(wrap(fake).call("F") for fake in fakes))

    asyncio.run(main())


def test_cancelling_a_running_call_cancels_it_in_the_sdk() -> None:
    started, release = threading.Event(), threading.Event()

    def block() -> None:
        started.set()
        release.wait(TIMEOUT)

    class AbortingClient(FakeClient):
        def cancel(self) -> None:
            super().cancel()
            release.set()  # unblocks the call, as RfcCancel does

    fake = AbortingClient(block=block)

    async def main() -> None:
        task = asyncio.create_task(wrap(fake).call("F"))
        await asyncio.to_thread(started.wait, TIMEOUT)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(main())
    assert fake.cancelled == 1


def test_cancelling_a_queued_call_leaves_the_running_one_alone() -> None:
    started, release = threading.Event(), threading.Event()

    def block() -> None:
        started.set()
        release.wait(TIMEOUT)

    fake = FakeClient(block=block)

    async def main() -> None:
        conn = wrap(fake)
        running = asyncio.create_task(conn.call("F", REQUTEXT="first"))
        await asyncio.to_thread(started.wait, TIMEOUT)
        queued = asyncio.create_task(conn.call("F", REQUTEXT="second"))
        await asyncio.sleep(0)
        queued.cancel()
        with pytest.raises(asyncio.CancelledError):
            await queued
        release.set()
        assert await running == {"ECHOTEXT": "first"}

    asyncio.run(main())
    assert fake.cancelled == 0
    assert len(fake.calls) == 1


def test_async_with_closes_on_error() -> None:
    fake = FakeClient()

    async def main() -> None:
        async with wrap(fake):
            raise KeyError("boom")

    with pytest.raises(KeyError):
        asyncio.run(main())
    assert fake.calls[-1][0] == "close"


def test_open_raises_to_the_awaiter() -> None:
    with pytest.raises(ValueError, match="no connection parameters"):
        asyncio.run(AsyncRFCClient.open())
    with pytest.raises(TypeError, match="sysnr"):
        asyncio.run(AsyncRFCClient.open(ashost="h", sysnr=0))  # type: ignore[arg-type]


def test_closed_client_raises_typed_error() -> None:
    conn = AsyncRFCClient(RFCClient.__new__(RFCClient))
    assert repr(conn) == "<dragonrfc.AsyncRFCClient closed>"
    with pytest.raises(dragonrfc.RFCExternalRuntimeError):
        asyncio.run(conn.ping())
    asyncio.run(conn.close())
