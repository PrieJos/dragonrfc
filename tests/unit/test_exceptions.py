#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Unit tests for ``dragonrfc.exceptions``.

Pure Python: no SDK or SAP system needed.

API:
    - ``_info``: builds an ``ErrorInfo`` with overridable code, group and key.
    - Tests for the group-to-class mapping, the fallback for unknown values and
      the copied ``RFC_ERROR_INFO`` fields.

Example:
    $ task test
"""

import pytest

from dragonrfc.exceptions import (
    ErrorGroup,
    ErrorInfo,
    ReturnCode,
    RFCABAPApplicationError,
    RFCCommunicationError,
    RFCError,
    RFCLogonError,
    error_from_info,
)


def _info(code: int = 1, group: int = 4, key: str = "KEY") -> ErrorInfo:
    return {
        "code": code,
        "group": group,
        "key": key,
        "message": "something failed",
        "abap_msg_class": "00",
        "abap_msg_type": "E",
        "abap_msg_number": "001",
        "abap_msg_v1": "v1",
        "abap_msg_v2": "v2",
        "abap_msg_v3": "v3",
        "abap_msg_v4": "v4",
    }


@pytest.mark.parametrize(
    ("group", "cls"),
    [
        (ErrorGroup.ABAP_APPLICATION_FAILURE, RFCABAPApplicationError),
        (ErrorGroup.LOGON_FAILURE, RFCLogonError),
        (ErrorGroup.COMMUNICATION_FAILURE, RFCCommunicationError),
    ],
)
def test_group_selects_class(group: ErrorGroup, cls: type[RFCError]) -> None:
    exc = error_from_info(_info(group=group))
    assert type(exc) is cls
    assert isinstance(exc, RFCError)


def test_every_group_except_ok_has_a_subclass() -> None:
    for group in ErrorGroup:
        if group is not ErrorGroup.OK:
            assert type(error_from_info(_info(group=group))) is not RFCError


def test_unknown_group_falls_back_to_base() -> None:
    exc = error_from_info(_info(code=999, group=999))
    assert type(exc) is RFCError
    assert exc.code == 999
    assert exc.group == 999


def test_fields_are_copied() -> None:
    exc = error_from_info(_info(code=5, group=1, key="NOT_FOUND"))
    assert exc.code is ReturnCode.ABAP_EXCEPTION
    assert exc.group is ErrorGroup.ABAP_APPLICATION_FAILURE
    assert exc.key == "NOT_FOUND"
    assert exc.abap_msg_number == "001"
    assert exc.abap_msg_v4 == "v4"
    assert str(exc) == "NOT_FOUND: something failed"


def test_message_without_key() -> None:
    assert str(error_from_info(_info(key=""))) == "something failed"
