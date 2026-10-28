<!--
Copyright (c) 2026 F. Hoffmann-La Roche Ltd
Authors:
- ERP Technology Platform Team <glospot_members@msxdl.roche.com>
-->

# NW RFC SDK feature decisions

Checked against **SAP NW RFC SDK 7.50 PL20** (`sapnwrfc.h`, `sapucrfc.h`,
`doc/release_notes.txt`) on 2026-10-28. Record new decisions here so they are not
re-litigated.

## Build facts (verified in headers)

| Topic           | Finding                                                                                                                                                                    |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Compile defines | Only `SAPwithUNICODE` is required. `sapucrfc.h` derives `SAPonLIN` / `SAPonNT` / `SAPonDARW` and `SAPwith64_BIT` from compiler macros.                                     |
| `SAP_UC`        | `char16_t` with GCC/Clang, `wchar_t` on Windows (`WCHAR_is_2B`): always 2-byte UTF-16 in native byte order. dragonrfc converts with Python's UTF-16 codec at the boundary. |
| Link            | All used symbols live in `libsapnwrfc` (`sapnwrfc.lib` on Windows). `libsapucum` and ICU are loaded by the SDK itself.                                                     |
| Linux runpath   | `libsapnwrfc.so` has no SONAME and a fixed RUNPATH (`/opt/rh/SAP/lib64:/usr/sap/lib`). Dev builds add an rpath to `$SAPNWRFC_HOME/lib`; wheels rely on `LD_LIBRARY_PATH`.  |
| Error model     | `RFC_RC` (34 codes) and `RFC_ERROR_GROUP` (11 groups); exceptions map 1:1 to groups.                                                                                       |

## Features

| Feature                                                                                                           | Since       | Status                    | Notes                                                                                                                                                      |
| ----------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Client connection, ping, `RfcInvoke`                                                                              | –           | Supported (M1)            | GIL released around open, close, ping, metadata lookup and invoke.                                                                                         |
| Type conversion CHAR, NUM, STRING, DATE, TIME, BCD, DECF16/34, UTCLONG                                            | –           | Supported (M1)            | Via `RfcGetString` / `RfcSetString`, which the header documents for all these types.                                                                       |
| INT1/2/4/8, FLOAT, BYTE, XSTRING, structures, tables                                                              | –           | Supported (M1)            | Native getters/setters.                                                                                                                                    |
| UTCSECOND, UTCMINUTE, DTDAY, DTWEEK, DTMONTH, TSECOND, TMINUTE, CDAY                                              | 7.50        | Deferred                  | New ABAP types; `RfcGetString` does not list them. Raise `TypeError` for now.                                                                              |
| ABAP objects, BOX / GENERIC_BOX                                                                                   | –           | Not feasible / deferred   | Header says boxed types are not supported by the library.                                                                                                  |
| WebSocket RFC (`wshost`, `wsport`, TLS PSE, `WS_APPSERVER_INSTANCE` PL14)                                         | 7.50        | Supported as pass-through | Plain connection parameters; no API needed. Not yet tested live.                                                                                           |
| SNC logon (`snc_mode`, `snc_qop`, `snc_myname`, `snc_partnername`, `snc_lib`, `snc_sso`), `mysapsso2`, `x509cert` | –           | Supported as pass-through | Plain connection parameters (`RfcOpenConnection` docs, `demo/sapnwrfc.ini`). Unit test proves they reach the SNC layer; live SNC handshake not yet tested. |
| `RfcGetPartnerSNCName` / `RfcGetPartnerSNCKey`                                                                    | –           | Not feasible on clients   | Header: server connections only, `RFC_ILLEGAL_STATE` on a client connection; `RFC_ATTRIBUTES` has no SNC field. Revisit with the RFC server.               |
| `RfcSNCNameToKey` / `RfcSNCKeyToName`                                                                             | –           | Deferred                  | Only needed for server-side access checks.                                                                                                                 |
| `GETSSO2` + `RfcGetPartnerSSOTicket`                                                                              | –           | Deferred                  | Returns a secret ticket; needs a design that keeps it out of repr/logs.                                                                                    |
| `RfcSetClientCipherSuites`                                                                                        | PL20        | Deferred                  | WebSocket TLS tuning; add with a config API.                                                                                                               |
| WebSocket ping/pong (`RfcSetWebsocketPingInterval`, `RfcSetWebsocketPongTimeout`)                                 | PL9 / PL13  | Deferred                  | Also settable via `sapnwrfc.ini`.                                                                                                                          |
| Password change handler (`RfcInstallPasswordChangeHandler`)                                                       | PL12        | Deferred                  | Needs a C callback into Python.                                                                                                                            |
| Trace components (`RfcSetTraceComponents`)                                                                        | PL19        | Deferred                  | Replaces trace levels; add with tracing API.                                                                                                               |
| `RfcUTF8ToSAPUC_CCE` / `RfcSAPUCToUTF8_CCE`                                                                       | PL15        | Not needed                | Python codecs handle conversion.                                                                                                                           |
| Max CPIC conversations, CPIC pong timeout                                                                         | PL11 / PL18 | Deferred                  | Global tuning knobs.                                                                                                                                       |
| Throughput (`RfcGetServerTime`, network read/write time)                                                          | PL8 / PL9   | Deferred                  | Milestone 2 candidate.                                                                                                                                     |
| RFC server, tRFC/qRFC/bgRFC, authentication handler                                                               | –           | Deferred                  | Out of scope for M1.                                                                                                                                       |
| Function metadata API (`RfcCreateFunctionDesc`, `RfcAddException` …)                                              | –           | Used internally           | Only for unit tests without an SAP system.                                                                                                                 |

## Metadata / repository (M2)

| Feature                                                                | Status    | Notes                                                                                                                                                                                                             |
| ---------------------------------------------------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RfcGetFunctionDesc` + parameter/exception readers                     | Supported | `RFCClient.describe_function`. Lookup runs without the GIL; descriptors are cache-owned, copied into frozen dataclasses, never destroyed.                                                                         |
| `RfcGetTypeDesc` + field readers, `RfcGetTypeName`, `RfcGetTypeLength` | Supported | `RFCClient.describe_type`; nested STRUCTURE/TABLE fields recurse.                                                                                                                                                 |
| `RfcRemoveFunctionDesc` / `RfcRemoveTypeDesc`                          | Supported | `evict_function` / `evict_type`. Repository ID is `RFC_ATTRIBUTES.sysId` (the cache is per system ID; NULL would mean the default repository). Behavior for a name not in the cache is undocumented; verify live. |
| `RfcMetadataBatchQuery` + query result API                             | Deferred  | Needs backend support (SAP Note 1456826) and `USE_REPOSITORY_ROUNDTRIP_OPTIMIZATION=1`.                                                                                                                           |
| `RfcGetClassDesc` and class attribute readers                          | Deferred  | ABAP objects are not supported by `call` yet.                                                                                                                                                                     |
| `RfcGetCached*Desc` (cache-only lookup)                                | Deferred  | No use case without a connection yet.                                                                                                                                                                             |
| `RfcAdd*Desc`, `RfcClearRepository`                                    | Deferred  | Belong with the RFC server milestone (hard-coded repositories).                                                                                                                                                   |
| `RfcSaveRepository` / `RfcLoadRepository`                              | Deferred  | `FILE*` based; needs a file-handle design.                                                                                                                                                                        |
| Newer RFCTYPEs in metadata                                             | Supported | `ABAPType` mirrors all `RFCTYPE` values up to `GENERIC_BOX`; unknown values stay plain ints.                                                                                                                      |
