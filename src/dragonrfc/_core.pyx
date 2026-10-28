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
      ``alive``, ``describe_function``, ``describe_type``, ``evict_function``,
      ``evict_type``; usable as a context manager.
    - :func:`sdk_version`: version of the loaded SDK.
    - ``_roundtrip``, ``_describe_test``: private test hooks for conversions and
      metadata without an SAP system.

Example:
    >>> with RFCClient(dest="MYSYS") as conn:
    ...     conn.call("STFC_CONNECTION", REQUTEXT="hi")["ECHOTEXT"]
    'hi'
"""

import datetime
import sys
from decimal import Decimal

from cpython.mem cimport PyMem_Free, PyMem_Malloc
from cpython.unicode cimport PyUnicode_DecodeUTF16
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
    const SAP_UC* name,
    RFCTYPE kind,
    RFC_TYPE_DESC_HANDLE type_desc,
    object value,
) except -1:
    cdef RFC_ERROR_INFO info
    cdef RFC_STRUCTURE_HANDLE child
    cdef RFC_STRUCTURE_HANDLE line
    cdef bytes text
    cdef const unsigned char[:] raw

    if kind == RFCTYPE_STRUCTURE:
        _check(RfcGetStructure(handle, name, &child, &info), &info)
        _fill_structure(child, type_desc, value)
    elif kind == RFCTYPE_TABLE:
        _check(RfcGetTable(handle, name, &child, &info), &info)
        for row in value:
            line = RfcAppendNewRow(child, &info)
            if line == NULL:
                raise _error(&info)
            _fill_structure(line, type_desc, row)
    elif kind == RFCTYPE_INT:
        _check(RfcSetInt(handle, name, _as_int(value), &info), &info)
    elif kind == RFCTYPE_INT1:
        _check(RfcSetInt1(handle, name, _as_int(value), &info), &info)
    elif kind == RFCTYPE_INT2:
        _check(RfcSetInt2(handle, name, _as_int(value), &info), &info)
    elif kind == RFCTYPE_INT8:
        _check(RfcSetInt8(handle, name, _as_int(value), &info), &info)
    elif kind == RFCTYPE_FLOAT:
        if not isinstance(value, (int, float)):
            raise TypeError(f"expected float, got {type(value).__name__}")
        _check(RfcSetFloat(handle, name, value, &info), &info)
    elif kind in (RFCTYPE_BYTE, RFCTYPE_XSTRING):
        if not isinstance(value, (bytes, bytearray)):
            raise TypeError(f"expected bytes, got {type(value).__name__}")
        raw = bytes(value)
        _set_raw(handle, name, kind, &raw[0] if len(raw) else NULL, len(raw))
    elif kind in (
        RFCTYPE_CHAR, RFCTYPE_NUM, RFCTYPE_STRING, RFCTYPE_DATE, RFCTYPE_TIME,
        RFCTYPE_BCD, RFCTYPE_DECF16, RFCTYPE_DECF34, RFCTYPE_UTCLONG,
    ):
        text = _to_uc(_to_text(kind, value))
        _check(
            RfcSetString(handle, name, _ptr(text), len(text) // 2 - 1, &info),
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
    const SAP_UC* name,
    RFCTYPE kind,
    const SAP_RAW* data,
    unsigned length,
) except -1:
    cdef RFC_ERROR_INFO info
    cdef SAP_RAW empty = 0
    if data == NULL:
        data = &empty
    if kind == RFCTYPE_BYTE:
        _check(RfcSetBytes(handle, name, data, length, &info), &info)
    else:
        _check(RfcSetXString(handle, name, data, length, &info), &info)
    return 0


cdef int _fill_structure(
    RFC_STRUCTURE_HANDLE handle, RFC_TYPE_DESC_HANDLE type_desc, object values
) except -1:
    cdef RFC_ERROR_INFO info
    cdef RFC_FIELD_DESC field
    cdef bytes name
    for key, value in values.items():
        name = _to_uc(key)
        _check(RfcGetFieldDescByName(type_desc, _ptr(name), &field, &info), &info)
        _set_value(handle, field.name, field.type, field.typeDescHandle, value)
    return 0


# --- SDK -> Python ---------------------------------------------------------

cdef str _get_text(DATA_CONTAINER_HANDLE handle, const SAP_UC* name):
    cdef RFC_ERROR_INFO info
    cdef SAP_UC small[256]
    cdef SAP_UC* buffer
    cdef unsigned length = 0
    cdef RFC_RC rc = RfcGetString(handle, name, small, _TEXT_BUFFER, &length, &info)
    if rc == RFC_OK:
        return _from_uc(small, length)
    if rc != RFC_BUFFER_TOO_SMALL:
        raise _error(&info)
    buffer = <SAP_UC*>PyMem_Malloc((length + 1) * sizeof(SAP_UC))
    if buffer == NULL:
        raise MemoryError()
    try:
        _check(
            RfcGetString(handle, name, buffer, length + 1, &length, &info), &info
        )
        return _from_uc(buffer, length)
    finally:
        PyMem_Free(buffer)


cdef bytes _get_xstring(DATA_CONTAINER_HANDLE handle, const SAP_UC* name):
    cdef RFC_ERROR_INFO info
    cdef SAP_RAW probe
    cdef SAP_RAW* buffer
    cdef unsigned length = 0
    cdef RFC_RC rc = RfcGetXString(handle, name, &probe, 0, &length, &info)
    if rc == RFC_OK:
        return b""
    if rc != RFC_BUFFER_TOO_SMALL:
        raise _error(&info)
    buffer = <SAP_RAW*>PyMem_Malloc(length)
    if buffer == NULL:
        raise MemoryError()
    try:
        _check(RfcGetXString(handle, name, buffer, length, &length, &info), &info)
        return buffer[:length]
    finally:
        PyMem_Free(buffer)


cdef bytes _get_bytes(
    DATA_CONTAINER_HANDLE handle, const SAP_UC* name, unsigned length
):
    cdef RFC_ERROR_INFO info
    cdef SAP_RAW* buffer = <SAP_RAW*>PyMem_Malloc(length or 1)
    if buffer == NULL:
        raise MemoryError()
    try:
        _check(RfcGetBytes(handle, name, buffer, length, &info), &info)
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
    const SAP_UC* name,
    RFCTYPE kind,
    RFC_TYPE_DESC_HANDLE type_desc,
    unsigned uc_length,
):
    cdef RFC_ERROR_INFO info
    cdef RFC_STRUCTURE_HANDLE child
    cdef RFC_INT int_value
    cdef RFC_INT1 int1_value
    cdef RFC_INT2 int2_value
    cdef RFC_INT8 int8_value
    cdef RFC_FLOAT float_value

    if kind == RFCTYPE_STRUCTURE:
        _check(RfcGetStructure(handle, name, &child, &info), &info)
        return _read_structure(child, type_desc)
    if kind == RFCTYPE_TABLE:
        _check(RfcGetTable(handle, name, &child, &info), &info)
        return _read_table(child, type_desc)
    if kind == RFCTYPE_INT:
        _check(RfcGetInt(handle, name, &int_value, &info), &info)
        return int_value
    if kind == RFCTYPE_INT1:
        _check(RfcGetInt1(handle, name, &int1_value, &info), &info)
        return int1_value
    if kind == RFCTYPE_INT2:
        _check(RfcGetInt2(handle, name, &int2_value, &info), &info)
        return int2_value
    if kind == RFCTYPE_INT8:
        _check(RfcGetInt8(handle, name, &int8_value, &info), &info)
        return int8_value
    if kind == RFCTYPE_FLOAT:
        _check(RfcGetFloat(handle, name, &float_value, &info), &info)
        return float_value
    if kind == RFCTYPE_BYTE:
        return _get_bytes(handle, name, uc_length)
    if kind == RFCTYPE_XSTRING:
        return _get_xstring(handle, name)
    if kind == RFCTYPE_CHAR:
        # ABAP CHAR is blank padded; trailing blanks carry no meaning.
        return _get_text(handle, name).rstrip()
    if kind in (RFCTYPE_NUM, RFCTYPE_STRING, RFCTYPE_UTCLONG):
        return _get_text(handle, name)
    if kind == RFCTYPE_DATE:
        return _parse_date(_get_text(handle, name))
    if kind == RFCTYPE_TIME:
        return _parse_time(_get_text(handle, name))
    if kind in (RFCTYPE_BCD, RFCTYPE_DECF16, RFCTYPE_DECF34):
        return Decimal(_get_text(handle, name))
    raise TypeError(f"ABAP type {kind} is not supported yet")


cdef dict _read_structure(
    RFC_STRUCTURE_HANDLE handle, RFC_TYPE_DESC_HANDLE type_desc
):
    cdef RFC_ERROR_INFO info
    cdef RFC_FIELD_DESC field
    cdef unsigned count, index
    cdef dict result = {}
    _check(RfcGetFieldCount(type_desc, &count, &info), &info)
    for index in range(count):
        _check(RfcGetFieldDescByIndex(type_desc, index, &field, &info), &info)
        result[_from_ucz(field.name)] = _get_value(
            handle, field.name, field.type, field.typeDescHandle, field.ucLength
        )
    return result


cdef list _read_table(RFC_TABLE_HANDLE handle, RFC_TYPE_DESC_HANDLE type_desc):
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
        rows.append(_read_structure(row, type_desc))
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


cdef class RFCClient:
    """Client connection to an SAP system.

    The connection is opened on construction and closed by :meth:`close`, by
    leaving a ``with`` block, or, as a last resort, when the object is collected.

    Example:
        >>> with RFCClient(ashost="host", sysnr="00", client="100",
        ...                 user="me", passwd="secret") as conn:
        ...     conn.call("STFC_CONNECTION", REQUTEXT="hello")["ECHOTEXT"]
        'hello'
    """

    cdef RFC_CONNECTION_HANDLE _handle

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
        cdef RFC_CONNECTION_HANDLE handle = self._handle
        if handle == NULL:
            return
        self._handle = NULL
        with nogil:
            rc = RfcCloseConnection(handle, &info)
        _check(rc, &info)

    def ping(self):
        """Sends a ping to the SAP system.

        Raises:
            RFCCommunicationError: If the system does not answer.
            RFCExternalRuntimeError: If the connection is closed.
        """
        cdef RFC_ERROR_INFO info
        cdef RFC_RC rc
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

        with nogil:
            desc = RfcGetFunctionDesc(self._handle, cname, &info)
        if desc == NULL:
            raise _error(&info)
        func = RfcCreateFunction(desc, &info)
        if func == NULL:
            raise _error(&info)
        try:
            _set_params(desc, func, params)
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
        with nogil:
            type_desc = RfcGetTypeDesc(self._handle, cname, &info)
        if type_desc == NULL:
            raise _error(&info)
        return _describe_type(type_desc)

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
        cdef RFC_ERROR_INFO info
        cdef bytes repository = self._repository_id()
        cdef bytes buffer = _to_uc(name)
        _check(RfcRemoveFunctionDesc(_ptr(repository), _ptr(buffer), &info), &info)

    def evict_type(self, str name):
        """Drops a type description from the SDK cache for this system.

        Args:
            name: DDIC structure or table type name.

        Raises:
            RFCExternalRuntimeError: If the connection is closed.
            RFCError: If the SDK rejects the removal.
        """
        cdef RFC_ERROR_INFO info
        cdef bytes repository = self._repository_id()
        cdef bytes buffer = _to_uc(name)
        _check(RfcRemoveTypeDesc(_ptr(repository), _ptr(buffer), &info), &info)

    cdef bytes _repository_id(self):
        # The SDK keeps one metadata cache per system ID.
        cdef RFC_ERROR_INFO info
        cdef RFC_ATTRIBUTES attributes
        _check(RfcGetConnectionAttributes(self._handle, &attributes, &info), &info)
        return _to_uc(_from_ucz(attributes.sysId))


# --- Function containers ---------------------------------------------------

cdef int _set_params(
    RFC_FUNCTION_DESC_HANDLE desc, RFC_FUNCTION_HANDLE func, dict params
) except -1:
    cdef RFC_ERROR_INFO info
    cdef RFC_PARAMETER_DESC param
    cdef bytes name
    for key, value in params.items():
        name = _to_uc(key)
        _check(RfcGetParameterDescByName(desc, _ptr(name), &param, &info), &info)
        _set_value(func, param.name, param.type, param.typeDescHandle, value)
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
                func, param.name, param.type, param.typeDescHandle, param.ucLength
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
