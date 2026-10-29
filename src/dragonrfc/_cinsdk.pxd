#
# Copyright (c) 2026 F. Hoffmann-La Roche Ltd
# Authors:
# - ERP Technology Platform Team <glospot_members@msxdl.roche.com>
#
# Extern declarations for the subset of sapnwrfc.h (NW RFC SDK 7.50) used by
# dragonrfc. Signatures are copied from the SDK header; keep them in sync.

from libc.stdio cimport FILE


cdef extern from "<stdio.h>" nogil:
    # POSIX name; MSVC still exports it (as a deprecated alias of _fdopen).
    FILE* fdopen(int fd, const char* mode)


cdef extern from "sapnwrfc.h" nogil:
    # SAP_UC is char16_t (Linux/macOS) or wchar_t (Windows): always 2 bytes.
    ctypedef unsigned short SAP_UC
    ctypedef unsigned char SAP_RAW
    ctypedef SAP_UC RFC_CHAR
    ctypedef SAP_UC RFC_NUM
    ctypedef SAP_RAW RFC_BYTE
    ctypedef SAP_RAW RFC_INT1
    ctypedef short RFC_INT2
    ctypedef int RFC_INT
    ctypedef long long RFC_INT8
    ctypedef double RFC_FLOAT
    ctypedef RFC_CHAR RFC_ABAP_NAME[31]
    ctypedef RFC_CHAR RFC_PARAMETER_DEFVALUE[31]
    ctypedef RFC_CHAR RFC_PARAMETER_TEXT[80]

    ctypedef enum RFCTYPE:
        RFCTYPE_CHAR
        RFCTYPE_DATE
        RFCTYPE_BCD
        RFCTYPE_TIME
        RFCTYPE_BYTE
        RFCTYPE_TABLE
        RFCTYPE_NUM
        RFCTYPE_FLOAT
        RFCTYPE_INT
        RFCTYPE_INT2
        RFCTYPE_INT1
        RFCTYPE_STRUCTURE
        RFCTYPE_DECF16
        RFCTYPE_DECF34
        RFCTYPE_STRING
        RFCTYPE_XSTRING
        RFCTYPE_INT8
        RFCTYPE_UTCLONG

    ctypedef enum RFC_RC:
        RFC_OK
        RFC_BUFFER_TOO_SMALL
        RFC_TABLE_MOVE_EOF

    ctypedef enum RFC_ERROR_GROUP:
        pass

    ctypedef enum RFC_DIRECTION:
        RFC_IMPORT
        RFC_EXPORT
        RFC_CHANGING
        RFC_TABLES

    ctypedef struct RFC_ERROR_INFO:
        RFC_RC code
        RFC_ERROR_GROUP group
        SAP_UC key[128]
        SAP_UC message[512]
        SAP_UC abapMsgClass[21]
        SAP_UC abapMsgType[2]
        RFC_NUM abapMsgNumber[4]
        SAP_UC abapMsgV1[51]
        SAP_UC abapMsgV2[51]
        SAP_UC abapMsgV3[51]
        SAP_UC abapMsgV4[51]

    ctypedef struct RFC_CONNECTION_PARAMETER:
        const SAP_UC* name
        const SAP_UC* value

    cdef struct _RFC_CONNECTION_HANDLE:
        pass
    ctypedef _RFC_CONNECTION_HANDLE* RFC_CONNECTION_HANDLE

    cdef struct _RFC_TYPE_DESC_HANDLE:
        pass
    ctypedef _RFC_TYPE_DESC_HANDLE* RFC_TYPE_DESC_HANDLE

    cdef struct _RFC_FUNCTION_DESC_HANDLE:
        pass
    ctypedef _RFC_FUNCTION_DESC_HANDLE* RFC_FUNCTION_DESC_HANDLE

    cdef struct RFC_DATA_CONTAINER:
        pass
    ctypedef RFC_DATA_CONTAINER* DATA_CONTAINER_HANDLE
    ctypedef DATA_CONTAINER_HANDLE RFC_STRUCTURE_HANDLE
    ctypedef DATA_CONTAINER_HANDLE RFC_FUNCTION_HANDLE
    ctypedef DATA_CONTAINER_HANDLE RFC_TABLE_HANDLE

    ctypedef struct RFC_FIELD_DESC:
        RFC_ABAP_NAME name
        RFCTYPE type
        unsigned nucLength
        unsigned nucOffset
        unsigned ucLength
        unsigned ucOffset
        unsigned decimals
        RFC_TYPE_DESC_HANDLE typeDescHandle

    ctypedef struct RFC_PARAMETER_DESC:
        RFC_ABAP_NAME name
        RFCTYPE type
        RFC_DIRECTION direction
        unsigned nucLength
        unsigned ucLength
        unsigned decimals
        RFC_TYPE_DESC_HANDLE typeDescHandle
        RFC_PARAMETER_DEFVALUE defaultValue
        RFC_PARAMETER_TEXT parameterText
        RFC_BYTE optional

    ctypedef struct RFC_EXCEPTION_DESC:
        SAP_UC key[128]
        SAP_UC message[512]

    # Only the members dragonrfc reads.
    ctypedef struct RFC_ATTRIBUTES:
        SAP_UC sysId[9]

    # General
    const SAP_UC* RfcGetVersion(
        unsigned* majorVersion, unsigned* minorVersion, unsigned* patchLevel)

    # Connection
    RFC_CONNECTION_HANDLE RfcOpenConnection(
        const RFC_CONNECTION_PARAMETER* connectionParams, unsigned paramCount,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcCloseConnection(
        RFC_CONNECTION_HANDLE rfcHandle, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcIsConnectionHandleValid(
        RFC_CONNECTION_HANDLE rfcHandle, int* isValid, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcPing(RFC_CONNECTION_HANDLE rfcHandle, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcInvoke(
        RFC_CONNECTION_HANDLE rfcHandle, RFC_FUNCTION_HANDLE funcHandle,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetConnectionAttributes(
        RFC_CONNECTION_HANDLE rfcHandle, RFC_ATTRIBUTES* attr,
        RFC_ERROR_INFO* errorInfo)

    # Repository
    RFC_FUNCTION_DESC_HANDLE RfcGetFunctionDesc(
        RFC_CONNECTION_HANDLE rfcHandle, const SAP_UC* funcName,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcRemoveFunctionDesc(
        const SAP_UC* repositoryID, const SAP_UC* functionName,
        RFC_ERROR_INFO* errorInfo)
    RFC_TYPE_DESC_HANDLE RfcGetTypeDesc(
        RFC_CONNECTION_HANDLE rfcHandle, const SAP_UC* typeName,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcRemoveTypeDesc(
        const SAP_UC* repositoryID, const SAP_UC* typeName,
        RFC_ERROR_INFO* errorInfo)
    RFC_FUNCTION_DESC_HANDLE RfcGetCachedFunctionDesc(
        const SAP_UC* repositoryID, const SAP_UC* funcName,
        RFC_ERROR_INFO* errorInfo)
    RFC_TYPE_DESC_HANDLE RfcGetCachedTypeDesc(
        const SAP_UC* repositoryID, const SAP_UC* typeName,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcAddFunctionDesc(
        const SAP_UC* repositoryID, RFC_FUNCTION_DESC_HANDLE funcDesc,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcAddTypeDesc(
        const SAP_UC* repositoryID, RFC_TYPE_DESC_HANDLE typeHandle,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcClearRepository(
        const SAP_UC* repositoryID, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSaveRepository(
        const SAP_UC* repositoryID, FILE* const targetStream,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcLoadRepository(
        const SAP_UC* repositoryID, FILE* const targetStream,
        RFC_ERROR_INFO* errorInfo)

    # Metadata batch query
    ctypedef void* RFC_METADATA_QUERY_RESULT_HANDLE

    ctypedef struct RFC_METADATA_QUERY_RESULT_ENTRY:
        RFC_ABAP_NAME name
        SAP_UC errorMessage[512]

    ctypedef enum RFC_METADATA_OBJ_TYPE:
        RFC_METADATA_FUNCTION
        RFC_METADATA_TYPE
        RFC_METADATA_CLASS

    RFC_METADATA_QUERY_RESULT_HANDLE RfcCreateMetadataQueryResult(
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcDestroyMetadataQueryResult(
        RFC_METADATA_QUERY_RESULT_HANDLE handle, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcDescribeMetadataQueryResult(
        RFC_METADATA_QUERY_RESULT_HANDLE handle, RFC_METADATA_OBJ_TYPE type,
        unsigned* successful, unsigned* failed, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetMetadataQueryFailedEntry(
        RFC_METADATA_QUERY_RESULT_HANDLE handle, RFC_METADATA_OBJ_TYPE type,
        unsigned index, RFC_METADATA_QUERY_RESULT_ENTRY* entry,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcMetadataBatchQuery(
        RFC_CONNECTION_HANDLE rfcHandle, const SAP_UC** functionNames,
        unsigned functionCount, const SAP_UC** typeNames, unsigned typeCount,
        const SAP_UC** classNames, unsigned classCount,
        RFC_METADATA_QUERY_RESULT_HANDLE handle, RFC_ERROR_INFO* errorInfo)

    # Metadata
    RFC_RC RfcGetFunctionName(
        RFC_FUNCTION_DESC_HANDLE funcDesc, RFC_ABAP_NAME bufferForName,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetExceptionCount(
        RFC_FUNCTION_DESC_HANDLE funcDesc, unsigned* count,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetExceptionDescByIndex(
        RFC_FUNCTION_DESC_HANDLE funcDesc, unsigned index,
        RFC_EXCEPTION_DESC* excDesc, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcAddException(
        RFC_FUNCTION_DESC_HANDLE funcDesc, const RFC_EXCEPTION_DESC* excDesc,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetTypeName(
        RFC_TYPE_DESC_HANDLE typeHandle, RFC_ABAP_NAME bufferForName,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetTypeLength(
        RFC_TYPE_DESC_HANDLE typeHandle, unsigned* nucByteLength,
        unsigned* ucByteLength, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetParameterCount(
        RFC_FUNCTION_DESC_HANDLE funcDesc, unsigned* count,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetParameterDescByIndex(
        RFC_FUNCTION_DESC_HANDLE funcDesc, unsigned index,
        RFC_PARAMETER_DESC* paramDesc, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetParameterDescByName(
        RFC_FUNCTION_DESC_HANDLE funcDesc, const SAP_UC* name,
        RFC_PARAMETER_DESC* paramDesc, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetFieldCount(
        RFC_TYPE_DESC_HANDLE typeHandle, unsigned* count,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetFieldDescByIndex(
        RFC_TYPE_DESC_HANDLE typeHandle, unsigned index,
        RFC_FIELD_DESC* fieldDescr, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetFieldDescByName(
        RFC_TYPE_DESC_HANDLE typeHandle, const SAP_UC* name,
        RFC_FIELD_DESC* fieldDescr, RFC_ERROR_INFO* errorInfo)

    RFC_TYPE_DESC_HANDLE RfcCreateTypeDesc(
        const SAP_UC* name, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcAddTypeField(
        RFC_TYPE_DESC_HANDLE typeHandle, const RFC_FIELD_DESC* fieldDescr,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetTypeLength(
        RFC_TYPE_DESC_HANDLE typeHandle, unsigned nucByteLength,
        unsigned ucByteLength, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcDestroyTypeDesc(
        RFC_TYPE_DESC_HANDLE typeHandle, RFC_ERROR_INFO* errorInfo)
    RFC_FUNCTION_DESC_HANDLE RfcCreateFunctionDesc(
        const SAP_UC* name, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcAddParameter(
        RFC_FUNCTION_DESC_HANDLE funcDesc, const RFC_PARAMETER_DESC* paramDescr,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcDestroyFunctionDesc(
        RFC_FUNCTION_DESC_HANDLE funcDesc, RFC_ERROR_INFO* errorInfo)

    # Function containers
    RFC_FUNCTION_HANDLE RfcCreateFunction(
        RFC_FUNCTION_DESC_HANDLE funcDescHandle, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcDestroyFunction(
        RFC_FUNCTION_HANDLE funcHandle, RFC_ERROR_INFO* errorInfo)

    # Tables
    RFC_RC RfcGetRowCount(
        RFC_TABLE_HANDLE tableHandle, unsigned* rowCount,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcMoveTo(
        RFC_TABLE_HANDLE tableHandle, unsigned index, RFC_ERROR_INFO* errorInfo)
    RFC_STRUCTURE_HANDLE RfcGetCurrentRow(
        RFC_TABLE_HANDLE tableHandle, RFC_ERROR_INFO* errorInfo)
    RFC_STRUCTURE_HANDLE RfcAppendNewRow(
        RFC_TABLE_HANDLE tableHandle, RFC_ERROR_INFO* errorInfo)

    # Getters
    RFC_RC RfcGetString(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        SAP_UC* stringBuffer, unsigned bufferLength, unsigned* stringLength,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetBytes(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        SAP_RAW* byteBuffer, unsigned bufferLength, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetXString(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        SAP_RAW* byteBuffer, unsigned bufferLength, unsigned* xstringLength,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetInt(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name, RFC_INT* value,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetInt1(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name, RFC_INT1* value,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetInt2(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name, RFC_INT2* value,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetInt8(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name, RFC_INT8* value,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetFloat(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name, RFC_FLOAT* value,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetStructure(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        RFC_STRUCTURE_HANDLE* structHandle, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcGetTable(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        RFC_TABLE_HANDLE* tableHandle, RFC_ERROR_INFO* errorInfo)

    # Setters
    RFC_RC RfcSetString(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const SAP_UC* stringValue, unsigned valueLength,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetBytes(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const SAP_RAW* byteValue, unsigned valueLength,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetXString(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const SAP_RAW* byteValue, unsigned valueLength,
        RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetInt(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const RFC_INT value, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetInt1(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const RFC_INT1 value, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetInt2(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const RFC_INT2 value, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetInt8(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const RFC_INT8 value, RFC_ERROR_INFO* errorInfo)
    RFC_RC RfcSetFloat(
        DATA_CONTAINER_HANDLE dataHandle, const SAP_UC* name,
        const RFC_FLOAT value, RFC_ERROR_INFO* errorInfo)
