<!--
Copyright (c) 2026 F. Hoffmann-La Roche Ltd
Authors:
- ERP Technology Platform Team <glospot_members@msxdl.roche.com>
-->

# DragonRFC

Typed Python bindings for the [SAP NetWeaver RFC SDK](https://support.sap.com/en/product/connectors/nwrfcsdk.html), written in Cython. Python 3.11+, Linux, macOS and Windows.

The SDK is proprietary and is **not** bundled. Download it from SAP and:

- set `SAPNWRFC_HOME` to its directory (needs `include/` and `lib/`) to build;
- at runtime, make `$SAPNWRFC_HOME/lib` findable: `LD_LIBRARY_PATH` (Linux), `DYLD_LIBRARY_PATH` (macOS), or keep `SAPNWRFC_HOME` set (Windows).

```python
import dragonrfc

with dragonrfc.RFCClient(
    ashost="host", sysnr="00", client="100", user="me", passwd="secret"
) as conn:
    result = conn.call("STFC_CONNECTION", REQUTEXT="hello")
    print(result["ECHOTEXT"])
```

## SNC and single sign-on

Logon parameters go to the SDK unchanged, so SNC replaces `user`/`passwd` with the `snc_*` parameters. Values must be strings (`snc_qop="9"`, not `9`).

```python
conn = dragonrfc.RFCClient(
    ashost="host",
    sysnr="00",
    client="100",
    snc_mode="1",
    snc_qop="9",
    snc_myname="p:CN=me, O=Example",
    snc_partnername="p:CN=PRD, O=Example",
    snc_lib="/usr/sap/lib/libsapcrypto.so",  # or set SNC_LIB / SNC_LIB_64
)
```

`mysapsso2` (SSO2 ticket) and `x509cert` (X.509 certificate) work the same way. See `demo/sapnwrfc.ini` in the SDK for all parameters.

## ABAP to Python types

| ABAP                                                  | Python                                |
| ----------------------------------------------------- | ------------------------------------- |
| CHAR (trailing blanks stripped), NUM, STRING, UTCLONG | `str`                                 |
| INT1, INT2, INT4, INT8                                | `int`                                 |
| FLOAT                                                 | `float`                               |
| P (BCD), DECFLOAT16/34                                | `decimal.Decimal`                     |
| DATS                                                  | `datetime.date` (`None` when initial) |
| TIMS                                                  | `datetime.time` (`None` when blank)   |
| RAW, XSTRING                                          | `bytes`                               |
| structure                                             | `dict[str, ...]`                      |
| table                                                 | `list[dict[str, ...]]`                |

## Inspecting metadata

```python
import dataclasses

meta = conn.describe_function("STFC_STRUCTURE")
for param in meta.parameters:
    print(param.name, param.direction.name, param.type.name, param.text)
print(dataclasses.asdict(meta))  # plain dicts, e.g. for JSON

conn.describe_type("RFCTEST")  # DDIC structure layout
conn.evict_function("STFC_STRUCTURE")  # after the signature changed in SE37
```

Descriptions are cached by the SDK per system ID; `evict_function` / `evict_type` drop a stale entry.

## Development

Needs [uv](https://docs.astral.sh/uv/) and [Task](https://taskfile.dev/).

```bash
export SAPNWRFC_HOME=/usr/local/nwrfcsdk
task setup     # build the extension in a uv-managed venv
task check     # format, lint, mypy, stubtest, unit tests
task test:sap  # integration tests, needs DRAGONRFC_* variables
```
