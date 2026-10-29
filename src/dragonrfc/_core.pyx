#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
"""Compiled core of dragonrfc.

Client connections to SAP systems over RFC. Python values are converted to and
from SDK containers here, and ``SAP_UC`` strings to and from ``str`` at the
boundary only. Every failing SDK call raises the matching
:class:`dragonrfc.exceptions.RFCError` subclass.

API:
    - :class:`RFCClient`: open on construction; ``ping``, ``call``, ``close``,
      ``cancel``, ``alive``, ``describe_function``, ``describe_type``, ``prefetch``,
      ``repository``, ``evict_function``, ``evict_type``; usable as a context
      manager.
    - :class:`Repository`: the SDK metadata cache of one system ID; cache-only
      ``describe_function``/``describe_type``, ``evict_function``,
      ``evict_type``, ``clear``, ``save`` and ``load`` (JSON file).
    - :func:`sdk_version`: version of the loaded SDK.
    - ``_roundtrip``, ``_describe_test``, ``_add_test_repository``: private test
      hooks for conversions and metadata without an SAP system.

Example:
    >>> with RFCClient(dest="MYSYS") as conn:
    ...     conn.call("STFC_CONNECTION", REQUTEXT="hi")["ECHOTEXT"]
    'hi'
"""

import datetime
import os
import sys
import threading
from decimal import Decimal

from cpython.mem cimport PyMem_Free, PyMem_Malloc
from cpython.unicode cimport PyUnicode_DecodeUTF16
from libc.errno cimport errno
from libc.stdio cimport fclose
from libc.string cimport memcpy, memset

from dragonrfc._cinsdk cimport *

from dragonrfc.exceptions import _as_enum, error_from_info
from dragonrfc.metadata import (
    ABAPType,
    Direction,
    ExceptionMetadata,
    FieldMetadata,
    FunctionMetadata,
    ParameterMetadata,
    TypeMetadata,
)

# SAP_UC is UTF-16 in native byte order.
cdef bint _LITTLE = sys.byteorder == "little"
cdef str _UC_CODEC = "utf-16-le" if _LITTLE else "utf-16-be"
cdef unsigned _TEXT_BUFFER = 256


# --- SAP_UC <-> str, at the boundary only ---------------------------------

cdef bytes _to_uc(str value):
    """Encodes ``value`` as a null-terminated SAP_UC buffer."""
    return (value + "\0").encode(_UC_CODEC)


cdef inline const SAP_UC* _ptr(bytes buffer):
    return <const SAP_UC*><const char*>buffer


cdef str _from_uc(const SAP_UC* buffer, Py_ssize_t length):
    cdef int order = -1 if _LITTLE else 1
    return PyUnicode_DecodeUTF16(<const char*>buffer, length * 2, NULL, &order)


cdef str _from_ucz(const SAP_UC* buffer):
    cdef Py_ssize_t length = 0
    while buffer[length]:
        length += 1
    return _from_uc(buffer, length)


# --- Error handling --------------------------------------------------------

cdef object _error(RFC_ERROR_INFO* info):
    return error_from_info({
        "code": <int>info.code,
        "group": <int>info.group,
        "key": _from_ucz(info.key),
        "message": _from_ucz(info.message),
        "abap_msg_class": _from_ucz(info.abapMsgClass),
        "abap_msg_type": _from_ucz(info.abapMsgType),
        "abap_msg_number": _from_ucz(info.abapMsgNumber),
        "abap_msg_v1": _from_ucz(info.abapMsgV1),
        "abap_msg_v2": _from_ucz(info.abapMsgV2),
        "abap_msg_v3": _from_ucz(info.abapMsgV3),
        "abap_msg_v4": _from_ucz(info.abapMsgV4),
    })


cdef inline int _check(RFC_RC rc, RFC_ERROR_INFO* info) except -1:
    if rc != RFC_OK:
        raise _error(info)
    return 0


# --- Field layouts ---------------------------------------------------------

cdef class _Layout:
    """Field descriptors of one structure type, read once and reused per row.

    Rows of a table share one layout, so the SDK is asked for each field
    descriptor and name once per call instead of once per row.
    """

    cdef RFC_TYPE_DESC_HANDLE type_desc
    cdef RFC_FIELD_DESC* fields
    cdef unsigned count
    cdef list names
    cdef list children
    cdef dict indexes

    def __dealloc__(self):
        PyMem_Free(self.fields)

    cdef _Layout nested(self, unsigned index):
        """Returns the layout of a structure or table field, else ``None``."""
        cdef _Layout layout
        if not _is_container(self.fields[index].type):
            return None
        layout = self.children[index]
        if layout is None:
            layout = _layout(self.fields[index].typeDescHandle)
            self.children[index] = layout
        return layout

    cdef Py_ssize_t find(self, str key) except -1:
        """Returns the index of the field named ``key``."""
        cdef RFC_ERROR_INFO info
        cdef RFC_FIELD_DESC field
        cdef bytes name
        index = self.indexes.get(key)
        if index is None:
            # The SDK resolves the name, so it decides what matches and fails.
            name = _to_uc(key)
            _check(
                RfcGetFieldDescByName(self.type_desc, _ptr(name), &field, &info),
                &info,
            )
            index = self.names.index(_from_ucz(field.name))
            self.indexes[key] = index
        return index


cdef inline bint _is_container(RFCTYPE kind) noexcept:
    return kind == RFCTYPE_STRUCTURE or kind == RFCTYPE_TABLE


cdef _Layout _layout(RFC_TYPE_DESC_HANDLE type_desc):
    cdef RFC_ERROR_INFO info
    cdef _Layout layout = _Layout.__new__(_Layout)
    cdef unsigned index
    layout.type_desc = type_desc
    _check(RfcGetFieldCount(type_desc, &layout.count, &info), &info)
    layout.fields = <RFC_FIELD_DESC*>PyMem_Malloc(
        (layout.count or 1) * sizeof(RFC_FIELD_DESC)
    )
    if layout.fields == NULL:
        raise MemoryError()
    layout.names = []
    for index in range(layout.count):
        _check(
            RfcGetFieldDescByIndex(type_desc, index, &layout.fields[index], &info),
            &info,
        )
        layout.names.append(_from_ucz(layout.fields[index].name))
    layout.children = [None] * layout.count
    layout.indexes = {}
    return layout


cdef _Layout _param_layout(RFC_PARAMETER_DESC* param):
    if _is_container(param.type):
        return _layout(param.typeDescHandle)
    return None


# --- Python -> SDK ---------------------------------------------------------

cdef str _to_text(RFCTYPE kind, object value):
    """Formats ``value`` as the string the SDK parses for a char-like type."""
    if isinstance(value, str):
        return value
    if kind == RFCTYPE_DATE and isinstance(value, datetime.date):
        return value.strftime("%Y%m%d")
    if kind == RFCTYPE_TIME and isinstance(value, datetime.time):
        return value.strftime("%H%M%S")
    if kind in (RFCTYPE_BCD, RFCTYPE_DECF16, RFCTYPE_DECF34) and isinstance(
        value, (int, float, Decimal)
    ):
        # Plain notation: avoids exponents such as "1E+2" in the SDK parser.
        return format(Decimal(str(value)), "f")
    if kind == RFCTYPE_NUM and isinstance(value, int):
        return str(value)
    raise TypeError(f"cannot convert {type(value).__name__} to ABAP type {kind}")


cdef int _set_value(
    DATA_CONTAINER_HANDLE handle,
    unsigned index,
    RFCTYPE kind,
    _Layout nested,
    object value,
) except -1:
    cdef RFC_ERROR_INFO info
    cdef RFC_STRUCTURE_HANDLE child
    cdef RFC_STRUCTURE_HANDLE line
    cdef bytes text
    cdef const unsigned char[:] raw

    if kind == RFCTYPE_STRUCTURE:
        _check(RfcGetStructureByIndex(handle, index, &child, &info), &info)
        _fill_structure(child, nested, value)
    elif kind == RFCTYPE_TABLE:
        _check(RfcGetTableByIndex(handle, index, &child, &info), &info)
        for row in value:
            line = RfcAppendNewRow(child, &info)
            if line == NULL:
                raise _error(&info)
            _fill_structure(line, nested, row)
    elif kind == RFCTYPE_INT:
        _check(RfcSetIntByIndex(handle, index, _as_int(value), &info), &info)
    elif kind == RFCTYPE_INT1:
        _check(RfcSetInt1ByIndex(handle, index, _as_int(value), &info), &info)
    elif kind == RFCTYPE_INT2:
        _check(RfcSetInt2ByIndex(handle, index, _as_int(value), &info), &info)
    elif kind == RFCTYPE_INT8:
        _check(RfcSetInt8ByIndex(handle, index, _as_int(value), &info), &info)
    elif kind == RFCTYPE_FLOAT:
        if not isinstance(value, (int, float)):
            raise TypeError(f"expected float, got {type(value).__name__}")
        _check(RfcSetFloatByIndex(handle, index, value, &info), &info)
    elif kind in (RFCTYPE_BYTE, RFCTYPE_XSTRING):
        if not isinstance(value, (bytes, bytearray)):
            raise TypeError(f"expected bytes, got {type(value).__name__}")
        raw = bytes(value)
        _set_raw(handle, index, kind, &raw[0] if len(raw) else NULL, len(raw))
    elif kind in (
        RFCTYPE_CHAR, RFCTYPE_NUM, RFCTYPE_STRING, RFCTYPE_DATE, RFCTYPE_TIME,
        RFCTYPE_BCD, RFCTYPE_DECF16, RFCTYPE_DECF34, RFCTYPE_UTCLONG,
    ):
        text = _to_uc(_to_text(kind, value))
        _check(
            RfcSetStringByIndex(
                handle, index, _ptr(text), len(text) // 2 - 1, &info
            ),
            &info,
        )
    else:
        raise TypeError(f"ABAP type {kind} is not supported yet")
    return 0


cdef object _as_int(object value):
    if not isinstance(value, int):
        raise TypeError(f"expected int, got {type(value).__name__}")
    return value


cdef int _set_raw(
    DATA_CONTAINER_HANDLE handle,
    unsigned index,
    RFCTYPE kind,
    const SAP_RAW* data,
    unsigned length,
) except -1:
    cdef RFC_ERROR_INFO info
    cdef SAP_RAW empty = 0
    if data == NULL:
        data = &empty
    if kind == RFCTYPE_BYTE:
        _check(RfcSetBytesByIndex(handle, index, data, length, &info), &info)
    else:
        _check(RfcSetXStringByIndex(handle, index, data, length, &info), &info)
    return 0


cdef int _fill_structure(
    RFC_STRUCTURE_HANDLE handle, _Layout layout, object values
) except -1:
    cdef Py_ssize_t index
    for key, value in values.items():
        index = layout.find(key)
        _set_value(
            handle, index, layout.fields[index].type, layout.nested(index), value
        )
    return 0


# --- SDK -> Python ---------------------------------------------------------

cdef str _get_text(DATA_CONTAINER_HANDLE handle, unsigned index):
    cdef RFC_ERROR_INFO info
    cdef SAP_UC small[256]
    cdef SAP_UC* buffer
    cdef unsigned length = 0
    cdef RFC_RC rc = RfcGetStringByIndex(
        handle, index, small, _TEXT_BUFFER, &length, &info
    )
    if rc == RFC_OK:
        return _from_uc(small, length)
    if rc != RFC_BUFFER_TOO_SMALL:
        raise _error(&info)
    buffer = <SAP_UC*>PyMem_Malloc((length + 1) * sizeof(SAP_UC))
    if buffer == NULL:
        raise MemoryError()
    try:
        _check(
            RfcGetStringByIndex(handle, index, buffer, length + 1, &length, &info),
            &info,
        )
        return _from_uc(buffer, length)
    finally:
        PyMem_Free(buffer)


cdef bytes _get_xstring(DATA_CONTAINER_HANDLE handle, unsigned index):
    cdef RFC_ERROR_INFO info
    cdef SAP_RAW probe
    cdef SAP_RAW* buffer
    cdef unsigned length = 0
    cdef RFC_RC rc = RfcGetXStringByIndex(handle, index, &probe, 0, &length, &info)
    if rc == RFC_OK:
        return b""
    if rc != RFC_BUFFER_TOO_SMALL:
        raise _error(&info)
    buffer = <SAP_RAW*>PyMem_Malloc(length)
    if buffer == NULL:
        raise MemoryError()
    try:
        _check(
            RfcGetXStringByIndex(handle, index, buffer, length, &length, &info),
            &info,
        )
        return buffer[:length]
    finally:
        PyMem_Free(buffer)


cdef bytes _get_bytes(
    DATA_CONTAINER_HANDLE handle, unsigned index, unsigned length
):
    cdef RFC_ERROR_INFO info
    cdef SAP_RAW* buffer = <SAP_RAW*>PyMem_Malloc(length or 1)
    if buffer == NULL:
        raise MemoryError()
    try:
        _check(RfcGetBytesByIndex(handle, index, buffer, length, &info), &info)
        return buffer[:length]
    finally:
        PyMem_Free(buffer)


cdef object _parse_date(str text):
    if not text.strip("0 "):
        return None
    return datetime.date(int(text[0:4]), int(text[4:6]), int(text[6:8]))


cdef object _parse_time(str text):
    if not text.strip():
        return None
    return datetime.time(int(text[0:2]), int(text[2:4]), int(text[4:6]))


cdef object _get_value(
    DATA_CONTAINER_HANDLE handle,
    unsigned index,
    RFCTYPE kind,
    unsigned uc_length,
    _Layout nested,
):
    cdef RFC_ERROR_INFO info
    cdef RFC_STRUCTURE_HANDLE child
    cdef RFC_INT int_value
    cdef RFC_INT1 int1_value
    cdef RFC_INT2 int2_value
    cdef RFC_INT8 int8_value
    cdef RFC_FLOAT float_value

    if kind == RFCTYPE_STRUCTURE:
        _check(RfcGetStructureByIndex(handle, index, &child, &info), &info)
        return _read_structure(child, nested)
    if kind == RFCTYPE_TABLE:
        _check(RfcGetTableByIndex(handle, index, &child, &info), &info)
        return _read_table(child, nested)
    if kind == RFCTYPE_INT:
        _check(RfcGetIntByIndex(handle, index, &int_value, &info), &info)
        return int_value
    if kind == RFCTYPE_INT1:
        _check(RfcGetInt1ByIndex(handle, index, &int1_value, &info), &info)
        return int1_value
    if kind == RFCTYPE_INT2:
        _check(RfcGetInt2ByIndex(handle, index, &int2_value, &info), &info)
        return int2_value
    if kind == RFCTYPE_INT8:
        _check(RfcGetInt8ByIndex(handle, index, &int8_value, &info), &info)
        return int8_value
    if kind == RFCTYPE_FLOAT:
        _check(RfcGetFloatByIndex(handle, index, &float_value, &info), &info)
        return float_value
    if kind == RFCTYPE_BYTE:
        return _get_bytes(handle, index, uc_length)
    if kind == RFCTYPE_XSTRING:
        return _get_xstring(handle, index)
    if kind == RFCTYPE_CHAR:
        # ABAP CHAR is blank padded; trailing blanks carry no meaning.
        return _get_text(handle, index).rstrip()
    if kind in (RFCTYPE_NUM, RFCTYPE_STRING, RFCTYPE_UTCLONG):
        return _get_text(handle, index)
    if kind == RFCTYPE_DATE:
        return _parse_date(_get_text(handle, index))
    if kind == RFCTYPE_TIME:
        return _parse_time(_get_text(handle, index))
    if kind in (RFCTYPE_BCD, RFCTYPE_DECF16, RFCTYPE_DECF34):
        return Decimal(_get_text(handle, index))
    raise TypeError(f"ABAP type {kind} is not supported yet")


cdef dict _read_structure(RFC_STRUCTURE_HANDLE handle, _Layout layout):
    cdef RFC_FIELD_DESC* field
    cdef unsigned index
    cdef dict result = {}
    for index in range(layout.count):
        field = &layout.fields[index]
        result[layout.names[index]] = _get_value(
            handle, index, field.type, field.ucLength, layout.nested(index)
        )
    return result


cdef list _read_table(RFC_TABLE_HANDLE handle, _Layout layout):
    cdef RFC_ERROR_INFO info
    cdef RFC_STRUCTURE_HANDLE row
    cdef unsigned count, index
    _check(RfcGetRowCount(handle, &count, &info), &info)
    rows = []
    for index in range(count):
        _check(RfcMoveTo(handle, index, &info), &info)
        row = RfcGetCurrentRow(handle, &info)
        if row == NULL:
            raise _error(&info)
        rows.append(_read_structure(row, layout))
    return rows


# --- Metadata --------------------------------------------------------------
# Descriptors from RfcGet*Desc belong to the SDK cache: copy, never destroy.

cdef object _describe_type(RFC_TYPE_DESC_HANDLE type_desc):
    cdef RFC_ERROR_INFO info
    cdef RFC_FIELD_DESC field
    cdef RFC_ABAP_NAME name
    cdef unsigned count, index, nuc_length, uc_length
    _check(RfcGetTypeName(type_desc, name, &info), &info)
    _check(RfcGetTypeLength(type_desc, &nuc_length, &uc_length, &info), &info)
    _check(RfcGetFieldCount(type_desc, &count, &info), &info)
    fields = []
    for index in range(count):
        _check(RfcGetFieldDescByIndex(type_desc, index, &field, &info), &info)
        fields.append(FieldMetadata(
            name=_from_ucz(field.name),
            type=_as_enum(ABAPType, <int>field.type),
            nuc_length=field.nucLength,
            nuc_offset=field.nucOffset,
            uc_length=field.ucLength,
            uc_offset=field.ucOffset,
            decimals=field.decimals,
            structure=_nested_type(field.type, field.typeDescHandle),
        ))
    return TypeMetadata(
        name=_from_ucz(name),
        nuc_length=nuc_length,
        uc_length=uc_length,
        fields=tuple(fields),
    )


cdef object _nested_type(RFCTYPE kind, RFC_TYPE_DESC_HANDLE type_desc):
    if kind in (RFCTYPE_STRUCTURE, RFCTYPE_TABLE) and type_desc != NULL:
        return _describe_type(type_desc)
    return None


cdef object _describe_function(RFC_FUNCTION_DESC_HANDLE desc):
    cdef RFC_ERROR_INFO info
    cdef RFC_PARAMETER_DESC param
    cdef RFC_EXCEPTION_DESC exc
    cdef RFC_ABAP_NAME name
    cdef unsigned count, index
    _check(RfcGetFunctionName(desc, name, &info), &info)
    _check(RfcGetParameterCount(desc, &count, &info), &info)
    params = []
    for index in range(count):
        _check(RfcGetParameterDescByIndex(desc, index, &param, &info), &info)
        params.append(ParameterMetadata(
            name=_from_ucz(param.name),
            type=_as_enum(ABAPType, <int>param.type),
            direction=Direction(<int>param.direction),
            nuc_length=param.nucLength,
            uc_length=param.ucLength,
            decimals=param.decimals,
            default=_from_ucz(param.defaultValue),
            text=_from_ucz(param.parameterText),
            optional=param.optional != 0,
            structure=_nested_type(param.type, param.typeDescHandle),
        ))
    _check(RfcGetExceptionCount(desc, &count, &info), &info)
    exceptions = []
    for index in range(count):
        _check(RfcGetExceptionDescByIndex(desc, index, &exc, &info), &info)
        exceptions.append(ExceptionMetadata(
            key=_from_ucz(exc.key), message=_from_ucz(exc.message)
        ))
    return FunctionMetadata(
        name=_from_ucz(name), parameters=tuple(params), exceptions=tuple(exceptions)
    )


cdef dict _query_failures(
    RFC_METADATA_QUERY_RESULT_HANDLE result, RFC_METADATA_OBJ_TYPE kind
):
    cdef RFC_ERROR_INFO info
    cdef RFC_METADATA_QUERY_RESULT_ENTRY entry
    cdef unsigned succeeded, failed, index
    cdef dict failures = {}
    _check(
        RfcDescribeMetadataQueryResult(result, kind, &succeeded, &failed, &info),
        &info,
    )
    for index in range(failed):
        _check(
            RfcGetMetadataQueryFailedEntry(result, kind, index, &entry, &info),
            &info,
        )
        failures[_from_ucz(entry.name)] = _from_ucz(entry.errorMessage)
    return failures


cdef int _stream_repository(
    const SAP_UC* repository, object path, bint save
) except -1:
    """Saves or loads ``repository`` through a C stream on ``path``."""
    cdef RFC_ERROR_INFO info
    cdef RFC_RC rc
    cdef FILE* stream
    cdef int fd
    # Python opens the path so every OS and path encoding works; the SDK gets a
    # duplicate descriptor wrapped in a FILE*.
    with open(path, "wb" if save else "rb") as file:
        fd = os.dup(file.fileno())
        stream = fdopen(fd, b"wb" if save else b"rb")
        if stream == NULL:
            os.close(fd)
            raise OSError(errno, os.strerror(errno), path)
        with nogil:
            if save:
                rc = RfcSaveRepository(repository, stream, &info)
            else:
                rc = RfcLoadRepository(repository, stream, &info)
        if fclose(stream) != 0 and rc == RFC_OK:
            raise OSError(errno, os.strerror(errno), path)
    _check(rc, &info)
    return 0


# --- Public API ------------------------------------------------------------

def sdk_version():
    """Returns the version of the loaded SAP NW RFC SDK.

    Returns:
        ``(major, minor, patch_level)``, e.g. ``(7500, 0, 20)``.

    Example:
        >>> sdk_version()
        (7500, 0, 20)
    """
    cdef unsigned major = 0, minor = 0, patch = 0
    RfcGetVersion(&major, &minor, &patch)
    return major, minor, patch


cdef class Repository:
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

    cdef bytes _id
    cdef object _sysid

    def __init__(self, sysid=None):
        """Selects the cache of a system.

        Args:
            sysid: SAP system ID, e.g. ``"ABC"``, or ``None`` for the SDK's
                default repository.

        Raises:
            TypeError: If ``sysid`` is neither ``str`` nor ``None``.
        """
        if sysid is not None and not isinstance(sysid, str):
            raise TypeError(f"sysid must be str or None, not {type(sysid).__name__}")
        self._sysid = sysid
        self._id = None if sysid is None else _to_uc(sysid)

    cdef inline const SAP_UC* _rid(self):
        return NULL if self._id is None else _ptr(self._id)

    def __repr__(self):
        return f"<dragonrfc.Repository {self._sysid!r}>"

    @property
    def sysid(self):
        """System ID of this cache, or ``None`` for the default repository."""
        return self._sysid

    def describe_function(self, str name):
        """Returns the cached signature of a function module.

        Args:
            name: Function module name, e.g. ``"STFC_CONNECTION"``.

        Returns:
            Parameters, with nested structure types, and classic exceptions.

        Raises:
            RFCError: If the function is not in this cache.
        """
        cdef RFC_ERROR_INFO info
        cdef bytes buffer = _to_uc(name)
        cdef RFC_FUNCTION_DESC_HANDLE desc = RfcGetCachedFunctionDesc(
            self._rid(), _ptr(buffer), &info
        )
        if desc == NULL:
            raise _error(&info)
        return _describe_function(desc)

    def describe_type(self, str name):
        """Returns the cached layout of a DDIC structure or table type.

        Args:
            name: Type name, e.g. ``"RFCTEST"``.

        Returns:
            Fields with offsets and lengths, with nested types.

        Raises:
            RFCError: If the type is not in this cache.
        """
        cdef RFC_ERROR_INFO info
        cdef bytes buffer = _to_uc(name)
        cdef RFC_TYPE_DESC_HANDLE type_desc = RfcGetCachedTypeDesc(
            self._rid(), _ptr(buffer), &info
        )
        if type_desc == NULL:
            raise _error(&info)
        return _describe_type(type_desc)

    def evict_function(self, str name):
        """Drops a function description from this cache.

        Use it after the function's signature changed in the backend; the next
        call or description reads it again from the DDIC.

        Args:
            name: Function module name.

        Raises:
            RFCError: If the SDK rejects the removal.
        """
        cdef RFC_ERROR_INFO info
        cdef bytes buffer = _to_uc(name)
        _check(RfcRemoveFunctionDesc(self._rid(), _ptr(buffer), &info), &info)

    def evict_type(self, str name):
        """Drops a type description from this cache.

        Args:
            name: DDIC structure or table type name.

        Raises:
            RFCError: If the SDK rejects the removal.
        """
        cdef RFC_ERROR_INFO info
        cdef bytes buffer = _to_uc(name)
        _check(RfcRemoveTypeDesc(self._rid(), _ptr(buffer), &info), &info)

    def clear(self):
        """Drops every description in this cache.

        Raises:
            RFCError: If the SDK rejects the request.
        """
        cdef RFC_ERROR_INFO info
        _check(RfcClearRepository(self._rid(), &info), &info)

    def save(self, path):
        """Writes the cached function descriptions to a JSON file.

        The file format is shared with SAP JCo and SAP NCo. Load it with
        :meth:`load` to skip DDIC lookups at start-up.

        Args:
            path: Target file; created or overwritten.

        Raises:
            OSError: If the file cannot be written.
            RFCError: If the SDK fails to serialize the cache.
        """
        _stream_repository(self._rid(), path, True)

    def load(self, path):
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
        _stream_repository(self._rid(), path, False)


cdef class RFCClient:
    """Client connection to an SAP system.

    The connection is opened on construction and closed by :meth:`close`, by
    leaving a ``with`` block, or, as a last resort, when the object is collected.

    A client can be shared between threads: calls on it run one at a time,
    each with the GIL released while it waits on the network. Open one client
    per thread to run calls in parallel.

    Example:
        >>> with RFCClient(ashost="host", sysnr="00", client="100",
        ...                 user="me", passwd="secret") as conn:
        ...     conn.call("STFC_CONNECTION", REQUTEXT="hello")["ECHOTEXT"]
        'hello'
    """

    cdef RFC_CONNECTION_HANDLE _handle
    # The SDK forbids using one handle from two threads at once (Programming
    # Guide 4.2.1): _lock serializes every use. _cancel_lock only guards reading
    # and clearing _handle, so cancel() and alive never wait for a running call;
    # both are meant to run beside it (alive only looks the handle up).
    cdef object _lock
    cdef object _cancel_lock

    def __cinit__(self):
        self._lock = threading.Lock()
        self._cancel_lock = threading.Lock()

    def __init__(self, **params):
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
        cdef RFC_ERROR_INFO info
        cdef RFC_CONNECTION_PARAMETER* cparams
        cdef RFC_CONNECTION_HANDLE handle
        cdef unsigned count = len(params)
        cdef unsigned index
        cdef bytes buffer

        if self._handle != NULL:
            raise RuntimeError("connection is already open")
        if not count:
            raise ValueError("no connection parameters given")
        for key, value in params.items():
            if not isinstance(value, str):
                raise TypeError(f"connection parameter {key!r} must be str")
        # Keep the encoded buffers alive until RfcOpenConnection returns.
        buffers = [_to_uc(item) for pair in params.items() for item in pair]
        cparams = <RFC_CONNECTION_PARAMETER*>PyMem_Malloc(
            count * sizeof(RFC_CONNECTION_PARAMETER)
        )
        if cparams == NULL:
            raise MemoryError()
        try:
            for index in range(count):
                buffer = buffers[2 * index]
                cparams[index].name = _ptr(buffer)
                buffer = buffers[2 * index + 1]
                cparams[index].value = _ptr(buffer)
            with nogil:
                handle = RfcOpenConnection(cparams, count, &info)
        finally:
            PyMem_Free(cparams)
        if handle == NULL:
            raise _error(&info)
        self._handle = handle

    def __dealloc__(self):
        cdef RFC_ERROR_INFO info
        if self._handle != NULL:
            # Backstop only: no way to report a failure from a finalizer.
            with nogil:
                RfcCloseConnection(self._handle, &info)
            self._handle = NULL

    def __enter__(self):
        """Returns the connection itself for use in a ``with`` block."""
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        """Closes the connection when leaving the ``with`` block."""
        self.close()

    def __repr__(self):
        return f"<dragonrfc.RFCClient {'open' if self.alive else 'closed'}>"

    @property
    def alive(self):
        """Whether the connection handle is open and valid."""
        cdef RFC_ERROR_INFO info
        cdef int valid = 0
        with self._cancel_lock:
            if self._handle == NULL:
                return False
            # A failing check means the handle is invalid, which is the answer.
            return (
                RfcIsConnectionHandleValid(self._handle, &valid, &info) == RFC_OK
                and valid != 0
            )

    def close(self):
        """Closes the connection. Calling it again has no effect.

        Raises:
            RFCError: If the SDK fails to close the connection.
        """
        cdef RFC_ERROR_INFO info
        cdef RFC_RC rc
        cdef RFC_CONNECTION_HANDLE handle
        with self._lock:
            with self._cancel_lock:
                handle = self._handle
                self._handle = NULL
            if handle == NULL:
                return
            with nogil:
                rc = RfcCloseConnection(handle, &info)
        _check(rc, &info)

    def cancel(self):
        """Aborts the call that another thread is running on this connection.

        The SDK closes the connection together with the call: the aborted call
        raises an :class:`RFCError` and the client is closed afterwards. Does
        nothing when the connection is closed or no call is waiting on the
        network. Safe to call from any thread at any time.
        """
        cdef RFC_ERROR_INFO info
        cdef RFC_RC rc
        with self._cancel_lock:
            if self._handle == NULL:
                return
            with nogil:
                rc = RfcCancel(self._handle, &info)
            # RFC_ILLEGAL_STATE means no call was running: nothing to abort.
            if rc == RFC_OK:
                # RfcCancel closed the connection; closing it again is wrong.
                self._handle = NULL

    def ping(self):
        """Sends a ping to the SAP system.

        Raises:
            RFCCommunicationError: If the system does not answer.
            RFCExternalRuntimeError: If the connection is closed.
        """
        cdef RFC_ERROR_INFO info
        cdef RFC_RC rc
        with self._lock:
            with nogil:
                rc = RfcPing(self._handle, &info)
        _check(rc, &info)

    def call(self, str name, **params):
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
        cdef RFC_ERROR_INFO info
        cdef RFC_RC rc
        cdef RFC_FUNCTION_DESC_HANDLE desc
        cdef RFC_FUNCTION_HANDLE func
        cdef bytes buffer = _to_uc(name)
        cdef const SAP_UC* cname = _ptr(buffer)

        # Lock only the handle: the function container belongs to this call, so
        # another thread's call can use the connection while this one converts.
        with self._lock:
            with nogil:
                desc = RfcGetFunctionDesc(self._handle, cname, &info)
        if desc == NULL:
            raise _error(&info)
        func = RfcCreateFunction(desc, &info)
        if func == NULL:
            raise _error(&info)
        try:
            _set_params(desc, func, params)
            with self._lock:
                with nogil:
                    rc = RfcInvoke(self._handle, func, &info)
            _check(rc, &info)
            result = _get_results(desc, func)
        except BaseException:
            # Already failing: keep the original error over a cleanup failure.
            RfcDestroyFunction(func, &info)
            raise
        _check(RfcDestroyFunction(func, &info), &info)
        return result

    def describe_function(self, str name):
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
        cdef RFC_ERROR_INFO info
        cdef RFC_FUNCTION_DESC_HANDLE desc
        cdef bytes buffer = _to_uc(name)
        cdef const SAP_UC* cname = _ptr(buffer)
        with self._lock:
            with nogil:
                desc = RfcGetFunctionDesc(self._handle, cname, &info)
        if desc == NULL:
            raise _error(&info)
        return _describe_function(desc)

    def describe_type(self, str name):
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
        cdef RFC_ERROR_INFO info
        cdef RFC_TYPE_DESC_HANDLE type_desc
        cdef bytes buffer = _to_uc(name)
        cdef const SAP_UC* cname = _ptr(buffer)
        with self._lock:
            with nogil:
                type_desc = RfcGetTypeDesc(self._handle, cname, &info)
        if type_desc == NULL:
            raise _error(&info)
        return _describe_type(type_desc)

    def prefetch(self, functions=(), types=()):
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
        cdef RFC_ERROR_INFO info
        cdef RFC_ERROR_INFO cleanup
        cdef RFC_RC rc
        cdef RFC_METADATA_QUERY_RESULT_HANDLE result
        cdef const SAP_UC** names
        cdef unsigned function_count, type_count, index
        cdef bytes buffer

        if isinstance(functions, str) or isinstance(types, str):
            raise TypeError("functions and types must be iterables of str")
        functions, types = list(functions), list(types)
        function_count, type_count = len(functions), len(types)
        # Keep the encoded buffers alive until RfcMetadataBatchQuery returns.
        buffers = [_to_uc(name) for name in functions + types]
        names = <const SAP_UC**>PyMem_Malloc(
            (len(buffers) or 1) * sizeof(SAP_UC*)
        )
        if names == NULL:
            raise MemoryError()
        try:
            for index in range(len(buffers)):
                buffer = buffers[index]
                names[index] = _ptr(buffer)
            result = RfcCreateMetadataQueryResult(&info)
            if result == NULL:
                raise _error(&info)
            try:
                with self._lock:
                    with nogil:
                        rc = RfcMetadataBatchQuery(
                            self._handle, names, function_count,
                            names + function_count, type_count, NULL, 0,
                            result, &info,
                        )
                failures = _query_failures(result, RFC_METADATA_TYPE)
                failures.update(_query_failures(result, RFC_METADATA_FUNCTION))
                # Failed lookups also fail the call: report them, not the rc.
                if rc != RFC_OK and not failures:
                    raise _error(&info)
            except BaseException:
                # Already failing: keep the original error over a cleanup failure.
                RfcDestroyMetadataQueryResult(result, &cleanup)
                raise
            _check(RfcDestroyMetadataQueryResult(result, &cleanup), &cleanup)
        finally:
            PyMem_Free(names)
        return failures

    @property
    def repository(self):
        """The SDK metadata cache of this connection's system.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
        """
        # The SDK keeps one metadata cache per system ID.
        cdef RFC_ERROR_INFO info
        cdef RFC_ATTRIBUTES attributes
        cdef RFC_RC rc
        with self._lock:
            rc = RfcGetConnectionAttributes(self._handle, &attributes, &info)
        _check(rc, &info)
        return Repository(_from_ucz(attributes.sysId))

    def evict_function(self, str name):
        """Drops a function description from the SDK cache for this system.

        Use it after the function's signature changed in the backend; the next
        call or description reads it again from the DDIC.

        Args:
            name: Function module name.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
            RFCError: If the SDK rejects the removal.
        """
        self.repository.evict_function(name)

    def evict_type(self, str name):
        """Drops a type description from the SDK cache for this system.

        Args:
            name: DDIC structure or table type name.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
            RFCError: If the SDK rejects the removal.
        """
        self.repository.evict_type(name)


# --- Function containers ---------------------------------------------------

cdef int _set_params(
    RFC_FUNCTION_DESC_HANDLE desc, RFC_FUNCTION_HANDLE func, dict params
) except -1:
    cdef RFC_ERROR_INFO info
    cdef RFC_PARAMETER_DESC param
    cdef unsigned count, index
    cdef bytes name
    cdef dict indexes = {}
    if params:
        _check(RfcGetParameterCount(desc, &count, &info), &info)
        for index in range(count):
            _check(RfcGetParameterDescByIndex(desc, index, &param, &info), &info)
            indexes[_from_ucz(param.name)] = index
    for key, value in params.items():
        # The SDK resolves the name, so it decides what matches and fails.
        name = _to_uc(key)
        _check(RfcGetParameterDescByName(desc, _ptr(name), &param, &info), &info)
        _set_value(
            func, indexes[_from_ucz(param.name)], param.type,
            _param_layout(&param), value,
        )
    return 0


cdef dict _get_results(RFC_FUNCTION_DESC_HANDLE desc, RFC_FUNCTION_HANDLE func):
    cdef RFC_ERROR_INFO info
    cdef RFC_PARAMETER_DESC param
    cdef unsigned count, index
    cdef dict result = {}
    _check(RfcGetParameterCount(desc, &count, &info), &info)
    for index in range(count):
        _check(RfcGetParameterDescByIndex(desc, index, &param, &info), &info)
        if param.direction & RFC_EXPORT:
            result[_from_ucz(param.name)] = _get_value(
                func, index, param.type, param.ucLength, _param_layout(&param)
            )
    return result


def _roundtrip(list fields, dict values):
    """Sets ``values`` into a locally defined function and reads them back.

    Test hook: exercises the conversions against real SDK containers without
    an SAP system. Each field ``(name, rfctype, nuc_length, uc_length,
    decimals)`` becomes a CHANGING parameter; the same fields also form the
    line type of a structure ``STRUCT`` and a table ``TABLE``.
    """
    cdef RFC_ERROR_INFO info
    cdef RFC_TYPE_DESC_HANDLE type_desc = NULL
    cdef RFC_FUNCTION_DESC_HANDLE desc = _build_test_desc(fields, &type_desc)
    cdef RFC_FUNCTION_HANDLE func = NULL
    try:
        func = RfcCreateFunction(desc, &info)
        if func == NULL:
            raise _error(&info)
        _set_params(desc, func, values)
        return _get_results(desc, func)
    finally:
        # Test hook only: cleanup failures cannot be reported over the result.
        if func != NULL:
            RfcDestroyFunction(func, &info)
        RfcDestroyFunctionDesc(desc, &info)
        RfcDestroyTypeDesc(type_desc, &info)


def _describe_test(list fields):
    """Describes the function that ``_roundtrip`` builds from ``fields``.

    Test hook: exercises the metadata readers without an SAP system.
    """
    cdef RFC_ERROR_INFO info
    cdef RFC_TYPE_DESC_HANDLE type_desc = NULL
    cdef RFC_FUNCTION_DESC_HANDLE desc = _build_test_desc(fields, &type_desc)
    try:
        return _describe_function(desc)
    finally:
        RfcDestroyFunctionDesc(desc, &info)
        RfcDestroyTypeDesc(type_desc, &info)


def _add_test_repository(str sysid, list fields):
    """Adds the ``_roundtrip`` function and its line type to ``sysid``'s cache.

    Test hook: exercises :class:`Repository` without an SAP system. The cache
    owns the descriptions afterwards; drop them with ``Repository.clear``.
    """
    cdef RFC_ERROR_INFO info
    cdef RFC_ERROR_INFO cleanup
    cdef RFC_TYPE_DESC_HANDLE type_desc = NULL
    cdef RFC_FUNCTION_DESC_HANDLE desc = _build_test_desc(fields, &type_desc)
    cdef bytes repository = _to_uc(sysid)
    if RfcAddTypeDesc(_ptr(repository), type_desc, &info) != RFC_OK:
        RfcDestroyFunctionDesc(desc, &cleanup)
        RfcDestroyTypeDesc(type_desc, &cleanup)
        raise _error(&info)
    if RfcAddFunctionDesc(_ptr(repository), desc, &info) != RFC_OK:
        # The type already belongs to the cache.
        RfcDestroyFunctionDesc(desc, &cleanup)
        raise _error(&info)


cdef RFC_FUNCTION_DESC_HANDLE _build_test_desc(
    list fields, RFC_TYPE_DESC_HANDLE* line
) except NULL:
    """Builds the local test function; the caller destroys both descs."""
    cdef RFC_ERROR_INFO info
    cdef RFC_TYPE_DESC_HANDLE type_desc
    cdef RFC_FUNCTION_DESC_HANDLE desc
    cdef RFC_FIELD_DESC field
    cdef RFC_PARAMETER_DESC param
    cdef RFC_EXCEPTION_DESC exc
    cdef unsigned nuc_offset = 0, uc_offset = 0
    cdef bytes buffer

    buffer = _to_uc("ZDRAGONRFC_LINE")
    type_desc = RfcCreateTypeDesc(_ptr(buffer), &info)
    if type_desc == NULL:
        raise _error(&info)
    buffer = _to_uc("ZDRAGONRFC_ROUNDTRIP")
    desc = RfcCreateFunctionDesc(_ptr(buffer), &info)
    if desc == NULL:
        # Already failing: report the original error, not a cleanup failure.
        RfcDestroyTypeDesc(type_desc, &info)
        raise _error(&info)
    try:
        for name, kind, nuc_length, uc_length, decimals in fields:
            memset(&field, 0, sizeof(field))
            _copy_uc(field.name, name, 31)
            field.type = kind
            field.nucLength, field.ucLength = nuc_length, uc_length
            field.nucOffset, field.ucOffset = nuc_offset, uc_offset
            field.decimals = decimals
            # Aligning every field to 8 bytes is valid for all scalar types.
            nuc_offset += (nuc_length + 7) // 8 * 8
            uc_offset += (uc_length + 7) // 8 * 8
            _check(RfcAddTypeField(type_desc, &field, &info), &info)

            memset(&param, 0, sizeof(param))
            _copy_uc(param.name, name, 31)
            param.type = kind
            param.direction = RFC_CHANGING
            param.nucLength, param.ucLength = nuc_length, uc_length
            param.decimals = decimals
            _check(RfcAddParameter(desc, &param, &info), &info)
        _check(RfcSetTypeLength(type_desc, nuc_offset, uc_offset, &info), &info)
        for name, kind, direction in (
            ("STRUCT", RFCTYPE_STRUCTURE, RFC_CHANGING),
            ("TABLE", RFCTYPE_TABLE, RFC_TABLES),
        ):
            memset(&param, 0, sizeof(param))
            _copy_uc(param.name, name, 31)
            param.type = kind
            param.direction = direction
            param.nucLength, param.ucLength = nuc_offset, uc_offset
            param.typeDescHandle = type_desc
            if kind == RFCTYPE_TABLE:
                # Covers the optional/text/default readers in _describe_test.
                param.optional = 1
                _copy_uc(param.parameterText, "Test lines", 80)
                _copy_uc(param.defaultValue, "SPACE", 31)
            _check(RfcAddParameter(desc, &param, &info), &info)
        memset(&exc, 0, sizeof(exc))
        _copy_uc(exc.key, "ZDRAGONRFC_FAILED", 128)
        _copy_uc(exc.message, "Test failure", 512)
        _check(RfcAddException(desc, &exc, &info), &info)
    except BaseException:
        RfcDestroyFunctionDesc(desc, &info)
        RfcDestroyTypeDesc(type_desc, &info)
        raise
    line[0] = type_desc
    return desc


cdef int _copy_uc(SAP_UC* target, str value, size_t size) except -1:
    """Copies ``value`` into a zeroed SAP_UC array of ``size`` units."""
    cdef bytes buffer = _to_uc(value)
    if <size_t>len(buffer) > size * sizeof(SAP_UC):
        raise ValueError(f"name too long: {value!r}")
    memcpy(target, _ptr(buffer), len(buffer))
    return 0
