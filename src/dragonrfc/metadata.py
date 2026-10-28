#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Metadata of function modules and DDIC types.

Immutable Python views of the SDK repository descriptors, returned by
:meth:`RFCClient.describe_function` and :meth:`RFCClient.describe_type`.
Fields map one to one to the SDK structures ``RFC_PARAMETER_DESC``,
``RFC_FIELD_DESC`` and ``RFC_EXCEPTION_DESC``.

API:
    - :class:`ABAPType`: mirror of ``RFCTYPE``.
    - :class:`Direction`: mirror of ``RFC_DIRECTION``.
    - :class:`FunctionMetadata`, :class:`ParameterMetadata`,
      :class:`ExceptionMetadata`, :class:`TypeMetadata`, :class:`FieldMetadata`:
      frozen dataclasses; ``dataclasses.asdict`` turns them into plain dicts.

Example:
    >>> meta = conn.describe_function("STFC_CONNECTION")
    >>> [p.name for p in meta.parameters if p.direction & Direction.IMPORT]
    ['REQUTEXT']
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum, IntFlag


class ABAPType(IntEnum):
    """ABAP data types, mirroring ``RFCTYPE`` in ``sapnwrfc.h``."""

    CHAR = 0
    DATE = 1
    BCD = 2
    TIME = 3
    BYTE = 4
    TABLE = 5
    NUM = 6
    FLOAT = 7
    INT = 8
    INT2 = 9
    INT1 = 10
    NULL = 14
    ABAPOBJECT = 16
    STRUCTURE = 17
    DECF16 = 23
    DECF34 = 24
    XMLDATA = 28
    STRING = 29
    XSTRING = 30
    INT8 = 31
    UTCLONG = 32
    UTCSECOND = 33
    UTCMINUTE = 34
    DTDAY = 35
    DTWEEK = 36
    DTMONTH = 37
    TSECOND = 38
    TMINUTE = 39
    CDAY = 40
    BOX = 41
    GENERIC_BOX = 42


class Direction(IntFlag):
    """Parameter directions, mirroring ``RFC_DIRECTION`` in ``sapnwrfc.h``."""

    IMPORT = 0x01
    EXPORT = 0x02
    CHANGING = IMPORT | EXPORT
    TABLES = 0x04 | CHANGING


@dataclass(frozen=True, slots=True, kw_only=True)
class FieldMetadata:
    """A field of a structure or table line type.

    Attributes:
        name: Field name.
        type: ABAP type. Values unknown to :class:`ABAPType` stay plain ints.
        nuc_length: Length in bytes in a non-Unicode system.
        nuc_offset: Offset in bytes in a non-Unicode system.
        uc_length: Length in bytes in a Unicode system.
        uc_offset: Offset in bytes in a Unicode system.
        decimals: Number of decimals for packed numbers.
        structure: Nested type for structure and table fields, else ``None``.
    """

    name: str
    type: ABAPType | int
    nuc_length: int
    nuc_offset: int
    uc_length: int
    uc_offset: int
    decimals: int
    structure: TypeMetadata | None


@dataclass(frozen=True, slots=True, kw_only=True)
class TypeMetadata:
    """A DDIC structure or table line type.

    Attributes:
        name: Type name, e.g. ``"RFCTEST"``.
        nuc_length: Total length in bytes in a non-Unicode system.
        uc_length: Total length in bytes in a Unicode system.
        fields: Fields in declaration order.
    """

    name: str
    nuc_length: int
    uc_length: int
    fields: tuple[FieldMetadata, ...]


@dataclass(frozen=True, slots=True, kw_only=True)
class ParameterMetadata:
    """A function module parameter.

    Attributes:
        name: Parameter name.
        type: ABAP type. Values unknown to :class:`ABAPType` stay plain ints.
        direction: Importing, exporting, changing or tables.
        nuc_length: Length in bytes in a non-Unicode system.
        uc_length: Length in bytes in a Unicode system.
        decimals: Number of decimals for packed numbers.
        default: Default value as defined in SE37, or ``""``.
        text: Description text as defined in SE37, or ``""``.
        optional: Whether the parameter is optional.
        structure: Structure type, or the line type for tables, else ``None``.
    """

    name: str
    type: ABAPType | int
    direction: Direction
    nuc_length: int
    uc_length: int
    decimals: int
    default: str
    text: str
    optional: bool
    structure: TypeMetadata | None


@dataclass(frozen=True, slots=True, kw_only=True)
class ExceptionMetadata:
    """A classic exception a function module can raise.

    Attributes:
        key: Exception key, e.g. ``"TABLE_NOT_AVAILABLE"``.
        message: Exception text as defined in SE37.
    """

    key: str
    message: str


@dataclass(frozen=True, slots=True, kw_only=True)
class FunctionMetadata:
    """The signature of a function module.

    Attributes:
        name: Function module name.
        parameters: Parameters in declaration order.
        exceptions: Classic exceptions.
    """

    name: str
    parameters: tuple[ParameterMetadata, ...]
    exceptions: tuple[ExceptionMetadata, ...]
