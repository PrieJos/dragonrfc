#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Integration tests against a real SAP system.

Marked ``sap`` and skipped unless ``DRAGONRFC_ASHOST``, ``DRAGONRFC_SYSNR``,
``DRAGONRFC_CLIENT``, ``DRAGONRFC_USER`` and ``DRAGONRFC_PASSWD`` are set. The
SNC test instead needs ``DRAGONRFC_SNC_PARTNERNAME`` (plus the host variables)
and optionally ``DRAGONRFC_SNC_MYNAME``, ``DRAGONRFC_SNC_LIB`` and
``DRAGONRFC_SNC_QOP``.

API:
    - ``params`` / ``conn`` fixtures: logon parameters and an open connection.
    - Tests for open/ping/close, SNC logon, logon errors, scalar and structure calls,
      ABAP exceptions, metadata lookups and cache eviction.

Example:
    $ DRAGONRFC_ASHOST=... task test:sap
"""

import os
from collections.abc import Iterator

import pytest

import dragonrfc

pytestmark = pytest.mark.sap

_ENV = {
    "ashost": "DRAGONRFC_ASHOST",
    "sysnr": "DRAGONRFC_SYSNR",
    "client": "DRAGONRFC_CLIENT",
    "user": "DRAGONRFC_USER",
    "passwd": "DRAGONRFC_PASSWD",
}


@pytest.fixture
def params() -> dict[str, str]:
    missing = [var for var in _ENV.values() if not os.environ.get(var)]
    if missing:
        pytest.skip(f"missing {', '.join(missing)}")
    return {key: os.environ[var] for key, var in _ENV.items()}


@pytest.fixture
def conn(params: dict[str, str]) -> Iterator[dragonrfc.RFCClient]:
    with dragonrfc.RFCClient(**params) as connection:
        yield connection


def test_open_ping_close(params: dict[str, str]) -> None:
    conn = dragonrfc.RFCClient(**params)
    assert conn.alive
    conn.ping()
    conn.close()
    assert not conn.alive
    conn.close()


def test_wrong_password(params: dict[str, str]) -> None:
    with pytest.raises(dragonrfc.RFCLogonError):
        dragonrfc.RFCClient(**{**params, "passwd": "definitely-wrong"})


def test_snc_logon() -> None:
    required = ("ashost", "sysnr", "client", "snc_partnername")
    missing = [f"DRAGONRFC_{k.upper()}" for k in required]
    missing = [var for var in missing if not os.environ.get(var)]
    if missing:
        pytest.skip(f"missing {', '.join(missing)}")
    logon = {"snc_mode": "1"}
    for key in (*required, "snc_myname", "snc_lib", "snc_qop"):
        if value := os.environ.get(f"DRAGONRFC_{key.upper()}"):
            logon[key] = value
    with dragonrfc.RFCClient(**logon) as conn:
        assert conn.call("STFC_CONNECTION", REQUTEXT="snc")["ECHOTEXT"] == "snc"


def test_stfc_connection(conn: dragonrfc.RFCClient) -> None:
    result = conn.call("STFC_CONNECTION", REQUTEXT="hello 🐉")
    assert result["ECHOTEXT"] == "hello 🐉"


def test_stfc_structure(conn: dragonrfc.RFCClient) -> None:
    row = {"RFCINT4": 42, "RFCCHAR4": "ABCD", "RFCFLOAT": 1.5}
    result = conn.call("STFC_STRUCTURE", IMPORTSTRUCT=row, RFCTABLE=[row])
    echo = result["ECHOSTRUCT"]
    table = result["RFCTABLE"]
    assert isinstance(echo, dict)
    assert isinstance(table, list)
    assert echo["RFCINT4"] == 42
    assert echo["RFCCHAR4"] == "ABCD"
    assert len(table) == 2


def test_unknown_function(conn: dragonrfc.RFCClient) -> None:
    # Error group not pinned yet: verify against a live system first.
    with pytest.raises(dragonrfc.RFCError):
        conn.call("Z_DRAGONRFC_DOES_NOT_EXIST")


def test_abap_exception(conn: dragonrfc.RFCClient) -> None:
    with pytest.raises(dragonrfc.RFCABAPApplicationError):
        conn.call("RFC_READ_TABLE", QUERY_TABLE="Z_DRAGONRFC_NO_TABLE")


def test_describe_function(conn: dragonrfc.RFCClient) -> None:
    meta = conn.describe_function("STFC_STRUCTURE")
    params = {p.name: p for p in meta.parameters}
    struct = params["IMPORTSTRUCT"].structure
    assert struct is not None
    assert struct.name == "RFCTEST"
    assert params["RFCTABLE"].direction is dragonrfc.Direction.TABLES
    assert conn.describe_type("RFCTEST") == struct


def test_describe_exceptions(conn: dragonrfc.RFCClient) -> None:
    meta = conn.describe_function("RFC_READ_TABLE")
    assert "TABLE_NOT_AVAILABLE" in {e.key for e in meta.exceptions}


def test_evict_then_describe(conn: dragonrfc.RFCClient) -> None:
    before = conn.describe_function("STFC_CONNECTION")
    conn.evict_function("STFC_CONNECTION")
    assert conn.describe_function("STFC_CONNECTION") == before
    conn.describe_type("RFCTEST")
    conn.evict_type("RFCTEST")


def test_describe_unknown_function(conn: dragonrfc.RFCClient) -> None:
    with pytest.raises(dragonrfc.RFCError):
        conn.describe_function("Z_DRAGONRFC_DOES_NOT_EXIST")
