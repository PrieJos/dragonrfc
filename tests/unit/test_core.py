#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Unit tests for the compiled ``dragonrfc._core`` extension.

They need the SDK but no SAP system: conversions run through locally defined
function descriptions via the ``_roundtrip`` and ``_describe_test`` hooks.

API:
    - ``FIELDS`` / ``VALUES``: one field and sample value per supported type.
    - Tests for type round trips, input validation, metadata readers, typed
      errors on closed or unreachable connections, and ``py.typed`` shipping.

Example:
    $ task test
"""

import dataclasses
import datetime
from decimal import Decimal
from importlib import resources

import pytest

import dragonrfc
from dragonrfc import ABAPType, Direction
from dragonrfc._core import _describe_test, _roundtrip

# (name, RFCTYPE, nuc_length, uc_length, decimals), values from sapnwrfc.h.
FIELDS = [
    ("CHAR", 0, 10, 20, 0),
    ("DATE", 1, 8, 16, 0),
    ("BCD", 2, 8, 8, 2),
    ("TIME", 3, 6, 12, 0),
    ("BYTE", 4, 4, 4, 0),
    ("NUM", 6, 5, 10, 0),
    ("FLOAT", 7, 8, 8, 0),
    ("INT", 8, 4, 4, 0),
    ("INT2", 9, 2, 2, 0),
    ("INT1", 10, 1, 1, 0),
    ("DECF16", 23, 8, 8, 0),
    ("DECF34", 24, 16, 16, 0),
    ("STRING", 29, 8, 8, 0),
    ("XSTRING", 30, 8, 8, 0),
    ("INT8", 31, 8, 8, 0),
]

VALUES: dict[str, object] = {
    "CHAR": "héllo 日本",
    "DATE": datetime.date(2026, 10, 28),
    "BCD": Decimal("-1234.56"),
    "TIME": datetime.time(23, 59, 1),
    "BYTE": b"\x00\x01\xfe\xff",
    "NUM": "00042",
    "FLOAT": 3.25,
    "INT": -2_000_000_000,
    "INT2": -32000,
    "INT1": 255,
    "DECF16": Decimal("1.5"),
    "DECF34": Decimal("-0.000000000001"),
    "STRING": "a" * 1000 + " 🐉",
    "XSTRING": bytes(range(256)) * 4,
    "INT8": 9_000_000_000_000_000_000,
}


def test_sdk_version() -> None:
    major, _, patch = dragonrfc.sdk_version()
    assert major >= 7500
    assert patch >= 0


def test_py_typed_ships() -> None:
    assert resources.files("dragonrfc").joinpath("py.typed").is_file()


def test_scalars_roundtrip() -> None:
    assert {k: v for k, v in _roundtrip(FIELDS, VALUES).items() if k in VALUES} == (
        VALUES
    )


def test_structure_and_table_roundtrip() -> None:
    row = {"CHAR": "x", "INT": 7, "DATE": datetime.date(2000, 2, 29)}
    result = _roundtrip(FIELDS, {"STRUCT": row, "TABLE": [row, {"INT": 1}]})
    struct = result["STRUCT"]
    table = result["TABLE"]
    assert isinstance(struct, dict)
    assert isinstance(table, list)
    assert {k: struct[k] for k in row} == row
    assert len(table) == 2
    assert table[1]["INT"] == 1
    assert table[1]["CHAR"] == ""


def test_initial_values() -> None:
    result = _roundtrip(FIELDS, {})
    assert result["CHAR"] == ""
    assert result["DATE"] is None
    assert result["TIME"] == datetime.time(0, 0)
    assert result["INT"] == 0
    assert result["XSTRING"] == b""
    assert result["TABLE"] == []


@pytest.mark.parametrize(
    ("field", "value", "text"),
    [
        ("DATE", "20260102", datetime.date(2026, 1, 2)),
        ("TIME", "010203", datetime.time(1, 2, 3)),
        ("BCD", 12, Decimal("12.00")),
        ("BCD", 0.5, Decimal("0.50")),
        ("NUM", 42, "00042"),
    ],
)
def test_accepted_input_forms(field: str, value: object, text: object) -> None:
    assert _roundtrip(FIELDS, {field: value})[field] == text


@pytest.mark.parametrize(
    ("field", "value", "error"),
    [
        ("INT", "1", TypeError),
        ("INT1", 256, OverflowError),
        ("FLOAT", "1.0", TypeError),
        ("BYTE", "00", TypeError),
        ("DATE", 20260101, TypeError),
        ("CHAR", 1, TypeError),
    ],
)
def test_rejected_input(field: str, value: object, error: type[Exception]) -> None:
    with pytest.raises(error):
        _roundtrip(FIELDS, {field: value})


def test_unknown_parameter_raises_rfc_error() -> None:
    with pytest.raises(dragonrfc.RFCError):
        _roundtrip(FIELDS, {"NOPE": 1})


def test_closed_connection_raises_typed_error() -> None:
    conn = dragonrfc.RFCClient.__new__(dragonrfc.RFCClient)
    assert not conn.alive
    assert repr(conn) == "<dragonrfc.RFCClient closed>"
    with pytest.raises(dragonrfc.RFCExternalRuntimeError) as info:
        conn.ping()
    assert info.value.code is dragonrfc.ReturnCode.INVALID_HANDLE
    for method in (
        conn.call,
        conn.describe_function,
        conn.describe_type,
        conn.evict_function,
        conn.evict_type,
    ):
        with pytest.raises(dragonrfc.RFCExternalRuntimeError) as info:
            method("STFC_CONNECTION")
        assert info.value.code is dragonrfc.ReturnCode.INVALID_HANDLE
    conn.close()  # no-op when already closed


def test_connection_parameter_validation() -> None:
    with pytest.raises(ValueError, match="no connection parameters"):
        dragonrfc.RFCClient()
    with pytest.raises(TypeError, match="sysnr"):
        dragonrfc.RFCClient(ashost="h", sysnr=0)  # type: ignore[arg-type]


def test_unreachable_host_raises_communication_error() -> None:
    with pytest.raises(dragonrfc.RFCCommunicationError):
        dragonrfc.RFCClient(
            ashost="127.0.0.1", sysnr="99", client="000", user="u", passwd="p"
        )


def test_snc_parameters_reach_the_sdk() -> None:
    # A missing GSS library fails in the SDK's SNC layer, before any network I/O.
    with pytest.raises(dragonrfc.RFCCommunicationError, match=r"SNC|GSS"):
        dragonrfc.RFCClient(
            ashost="127.0.0.1",
            sysnr="99",
            client="000",
            snc_mode="1",
            snc_qop="9",
            snc_partnername="p:CN=DRAGONRFC",
            snc_lib="/nonexistent/libsapcrypto.so",
        )


def test_describe_scalar_parameters() -> None:
    meta = _describe_test(FIELDS)
    assert meta.name == "ZDRAGONRFC_ROUNDTRIP"
    scalars = meta.parameters[: len(FIELDS)]
    assert [
        (p.name, p.type, p.nuc_length, p.uc_length, p.decimals) for p in scalars
    ] == FIELDS
    assert all(isinstance(p.type, ABAPType) for p in scalars)
    assert all(p.direction is Direction.CHANGING for p in scalars)
    assert all(p.structure is None for p in scalars)


def test_describe_structure_and_table() -> None:
    struct, table = _describe_test(FIELDS).parameters[len(FIELDS) :]
    assert struct.type is ABAPType.STRUCTURE
    assert table.type is ABAPType.TABLE
    assert table.direction is Direction.TABLES
    line = struct.structure
    assert line is not None
    assert line == table.structure
    assert line.name == "ZDRAGONRFC_LINE"
    assert (line.nuc_length, line.uc_length) == (struct.nuc_length, struct.uc_length)
    assert [
        (f.name, f.type, f.nuc_length, f.uc_length, f.decimals) for f in line.fields
    ] == (FIELDS)
    assert [f.uc_offset for f in line.fields[:3]] == [0, 24, 40]


def test_describe_texts_and_exceptions() -> None:
    meta = _describe_test(FIELDS)
    struct, table = meta.parameters[len(FIELDS) :]
    assert (struct.optional, struct.text, struct.default) == (False, "", "")
    assert (table.optional, table.text, table.default) == (True, "Test lines", "SPACE")
    assert [(e.key, e.message) for e in meta.exceptions] == [
        ("ZDRAGONRFC_FAILED", "Test failure")
    ]


def test_metadata_is_frozen_and_dumpable() -> None:
    meta = _describe_test(FIELDS)
    with pytest.raises(dataclasses.FrozenInstanceError):
        meta.name = "X"  # type: ignore[misc]
    dumped = dataclasses.asdict(meta)
    assert dumped["parameters"][-1]["structure"]["fields"][0]["name"] == "CHAR"
