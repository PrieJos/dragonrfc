#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Typed exceptions raised by dragonrfc.

Every failing SDK call fills an ``RFC_ERROR_INFO`` structure. Its ``group`` field
selects the exception class, so callers can catch failures by layer (network,
logon, ABAP, ...) and inspect the details on the instance.

API:
    - :class:`RFCError`: base class with the ``RFC_ERROR_INFO`` fields.
    - One :class:`RFCError` subclass per :class:`ErrorGroup` member except ``OK``.
    - :class:`ReturnCode`, :class:`ErrorGroup`: mirrors of ``RFC_RC`` and
      ``RFC_ERROR_GROUP``.
    - :class:`ErrorInfo`: ``TypedDict`` view of ``RFC_ERROR_INFO``.
    - :func:`error_from_info`: builds the exception for an error group.

Example:
    >>> try:
    ...     conn.call("BAPI_DOES_NOT_EXIST")
    ... except RFCABAPRuntimeError as exc:
    ...     print(exc.key, exc.message)
"""

from __future__ import annotations

from enum import IntEnum
from typing import TypedDict, TypeVar

_E = TypeVar("_E", bound=IntEnum)


class ReturnCode(IntEnum):
    """SDK return codes, mirroring ``RFC_RC`` in ``sapnwrfc.h``."""

    OK = 0
    COMMUNICATION_FAILURE = 1
    LOGON_FAILURE = 2
    ABAP_RUNTIME_FAILURE = 3
    ABAP_MESSAGE = 4
    ABAP_EXCEPTION = 5
    CLOSED = 6
    CANCELED = 7
    TIMEOUT = 8
    MEMORY_INSUFFICIENT = 9
    VERSION_MISMATCH = 10
    INVALID_PROTOCOL = 11
    SERIALIZATION_FAILURE = 12
    INVALID_HANDLE = 13
    RETRY = 14
    EXTERNAL_FAILURE = 15
    EXECUTED = 16
    NOT_FOUND = 17
    NOT_SUPPORTED = 18
    ILLEGAL_STATE = 19
    INVALID_PARAMETER = 20
    CODEPAGE_CONVERSION_FAILURE = 21
    CONVERSION_FAILURE = 22
    BUFFER_TOO_SMALL = 23
    TABLE_MOVE_BOF = 24
    TABLE_MOVE_EOF = 25
    START_SAPGUI_FAILURE = 26
    ABAP_CLASS_EXCEPTION = 27
    UNKNOWN_ERROR = 28
    AUTHORIZATION_FAILURE = 29
    AUTHENTICATION_FAILURE = 30
    CRYPTOLIB_FAILURE = 31
    IO_FAILURE = 32
    LOCKING_FAILURE = 33


class ErrorGroup(IntEnum):
    """SDK error groups, mirroring ``RFC_ERROR_GROUP`` in ``sapnwrfc.h``."""

    OK = 0
    ABAP_APPLICATION_FAILURE = 1
    ABAP_RUNTIME_FAILURE = 2
    LOGON_FAILURE = 3
    COMMUNICATION_FAILURE = 4
    EXTERNAL_RUNTIME_FAILURE = 5
    EXTERNAL_APPLICATION_FAILURE = 6
    EXTERNAL_AUTHORIZATION_FAILURE = 7
    EXTERNAL_AUTHENTICATION_FAILURE = 8
    CRYPTOLIB_FAILURE = 9
    LOCKING_FAILURE = 10


class ErrorInfo(TypedDict):
    """Python view of ``RFC_ERROR_INFO``."""

    code: int
    group: int
    key: str
    message: str
    abap_msg_class: str
    abap_msg_type: str
    abap_msg_number: str
    abap_msg_v1: str
    abap_msg_v2: str
    abap_msg_v3: str
    abap_msg_v4: str


class RFCError(Exception):
    """Base class for all errors reported by the NW RFC SDK.

    Attributes:
        code: SDK return code. Values outside :class:`ReturnCode` stay plain ints.
        group: SDK error group. Values outside :class:`ErrorGroup` stay plain ints.
        key: Error key, e.g. the ABAP exception name.
        message: Human-readable error text.
        abap_msg_class: ABAP message class (``SY-MSGID``).
        abap_msg_type: ABAP message type (``SY-MSGTY``), e.g. ``"E"``.
        abap_msg_number: ABAP message number (``SY-MSGNO``).
        abap_msg_v1: ABAP message variable 1 (``SY-MSGV1``).
        abap_msg_v2: ABAP message variable 2 (``SY-MSGV2``).
        abap_msg_v3: ABAP message variable 3 (``SY-MSGV3``).
        abap_msg_v4: ABAP message variable 4 (``SY-MSGV4``).
    """

    code: ReturnCode | int
    group: ErrorGroup | int

    def __init__(self, info: ErrorInfo) -> None:
        """Initializes the error from SDK error details.

        Args:
            info: Fields of the SDK ``RFC_ERROR_INFO`` structure.
        """
        self.code = _as_enum(ReturnCode, info["code"])
        self.group = _as_enum(ErrorGroup, info["group"])
        self.key = info["key"]
        self.message = info["message"]
        self.abap_msg_class = info["abap_msg_class"]
        self.abap_msg_type = info["abap_msg_type"]
        self.abap_msg_number = info["abap_msg_number"]
        self.abap_msg_v1 = info["abap_msg_v1"]
        self.abap_msg_v2 = info["abap_msg_v2"]
        self.abap_msg_v3 = info["abap_msg_v3"]
        self.abap_msg_v4 = info["abap_msg_v4"]
        super().__init__(f"{self.key}: {self.message}" if self.key else self.message)


class RFCABAPApplicationError(RFCError):
    """The function module raised a classic ABAP exception."""


class RFCABAPRuntimeError(RFCError):
    """ABAP runtime error or ABAP message (e.g. ``SYSTEM_FAILURE``)."""


class RFCLogonError(RFCError):
    """Logon to the SAP system failed."""


class RFCCommunicationError(RFCError):
    """Network or connection problem."""


class RFCExternalRuntimeError(RFCError):
    """Error inside the RFC library, e.g. an invalid parameter or conversion."""


class RFCExternalApplicationError(RFCError):
    """Error raised by external application code."""


class RFCExternalAuthorizationError(RFCError):
    """Error raised by an external authorization check."""


class RFCExternalAuthenticationError(RFCError):
    """Error raised by an external authentication handler."""


class RFCCryptoLibError(RFCError):
    """Error in the crypto library (TLS, SNC)."""


class RFCLockingError(RFCError):
    """Acquiring or releasing an SDK lock failed."""


_BY_GROUP: dict[int, type[RFCError]] = {
    ErrorGroup.ABAP_APPLICATION_FAILURE: RFCABAPApplicationError,
    ErrorGroup.ABAP_RUNTIME_FAILURE: RFCABAPRuntimeError,
    ErrorGroup.LOGON_FAILURE: RFCLogonError,
    ErrorGroup.COMMUNICATION_FAILURE: RFCCommunicationError,
    ErrorGroup.EXTERNAL_RUNTIME_FAILURE: RFCExternalRuntimeError,
    ErrorGroup.EXTERNAL_APPLICATION_FAILURE: RFCExternalApplicationError,
    ErrorGroup.EXTERNAL_AUTHORIZATION_FAILURE: RFCExternalAuthorizationError,
    ErrorGroup.EXTERNAL_AUTHENTICATION_FAILURE: RFCExternalAuthenticationError,
    ErrorGroup.CRYPTOLIB_FAILURE: RFCCryptoLibError,
    ErrorGroup.LOCKING_FAILURE: RFCLockingError,
}


def _as_enum(enum: type[_E], value: int) -> _E | int:
    try:
        return enum(value)
    except ValueError:
        return value


def error_from_info(info: ErrorInfo) -> RFCError:
    """Builds the exception matching the error group of ``info``.

    Args:
        info: Fields of the SDK ``RFC_ERROR_INFO`` structure.

    Returns:
        An instance of the :class:`RFCError` subclass for the error group, or
        :class:`RFCError` itself for unknown groups.
    """
    return _BY_GROUP.get(info["group"], RFCError)(info)
