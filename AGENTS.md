<!--
Copyright (c) 2026 F. Hoffmann-La Roche Ltd
Authors:
- ERP Technology Platform Team <glospot_members@msxdl.roche.com>
-->

# AGENTS.md

Guidance for AI coding agents working on `dragonrfc`.

## Project

`dragonrfc` is a Python wrapper, written in Cython, around the
[SAP NetWeaver RFC SDK](https://support.sap.com/en/product/connectors/nwrfcsdk.html)
(NW RFC SDK). It is a spiritual successor to the archived
[SAP-archive/PyRFC](https://github.com/SAP-archive/PyRFC).

- **PyRFC is inspiration only.** Read it to learn which SDK features matter and how
  users use them. Do not fork it or copy its code, structure, API names or docstrings.
  Reusing any PyRFC code needs the user's explicit approval, Apache 2.0 compliance and
  attribution.
- **Do not freeze at PyRFC's feature set.** Check the current SDK release notes and
  headers for newer features (APIs, protocols, SNC/TLS and auth, platforms, ICU,
  deprecations) and support them where feasible. Record each decision (supported,
  deferred, not feasible, with the reason) in `docs/sdk-features.md`.
- **Never invent SDK behavior** from PyRFC or memory. Verify it against the sources in
  [References](#references).

## Rules

1. **Typed (PEP 561).** Ship `py.typed` and a `.pyi` stub for every compiled module.
   Stubs are the public typing contract; change `.pyx` and `.pyi` in the same commit.
   Use precise types, avoid `Any` in the public API.
2. **Cross-platform.** Windows, macOS and Linux. Never write single-OS code.
3. **Python >= 3.11.** No compatibility shims for older versions.
4. **Google-style docstrings** on every exposed function, class, method and module,
   including `.pyx`. Private helpers only when the behavior is not obvious.
5. **Tooling:** `uv` is the only package manager (commit `uv.lock`; no `pip`, `poetry`
   or `conda`). `ruff` lints and formats, `mypy` runs in strict mode, `pytest` tests,
   and [Task](https://taskfile.dev/) runs every recurring workflow. CI and docs call
   `task <name>`, never raw commands, Makefiles or ad-hoc scripts.
6. **`.editorconfig` leads formatting.** Tool configs mirror it, never override it. If
   a file disagrees, fix the file or the config (config first), not by hand.
7. **GitHub** is the remote and CI/CD. Workflows in `.github/workflows/` call
   `task <name>`, run on Linux, macOS and Windows, and build wheels with
   `cibuildwheel`. The SDK reaches CI only through secrets or private artifacts. Use
   `gh` for PRs and issues.
8. **Every change must pass** `task format:check`, `task lint:check`, `task typecheck`,
   `task stubtest` and `task test` (plus `task test:sap` when the SDK and a SAP system
   are available). Never skip, delete or weaken a test to pass. No blanket `# noqa` or
   unjustified `# type: ignore`; silence per line with the code and a reason.
9. **SPOT header on every file**, from the `spotheader` snippet in
   `.vscode/spot.code-snippets`. Use the YAML variant (`---` and
   `# code: language=yaml`) for YAML, the generic one for other `#`-comment files, and
   the same text in the file's own comment syntax otherwise (e.g. `<!-- -->` in
   Markdown). Keep the file's creation year. JSON, `py.typed` and `uv.lock` are exempt.
   A shebang stays on line 1, above the header.
10. **Module docstring** right after the header in every `.py`, `.pyx` and `.pyi` file
    (including `__init__.py` and tests), kept in sync with the module's API:

    ```python
    """Short module title.

    Module explanation covering:
    - Module overview
    - Module API
    - Examples of usage.
    """
    ```

11. **Sync and async together.** Every public `RFCClient` method that can block (it
    reaches the network or the SDK may wait) gets an `AsyncRFCClient` method with the
    same name, arguments and return type in the same commit, plus a unit test in
    `tests/unit/test_aio.py`. Methods that only touch local state stay sync and are
    reached through `AsyncRFCClient.client`.

## Layout

`src/dragonrfc/` holds `__init__.py` (public re-exports, `__all__`, `__version__`),
`_cinsdk.pxd` (extern declarations from `sapnwrfc.h`), `_core.pyx` and `_core.pyi`,
`aio.py` (`AsyncRFCClient`, the asyncio wrapper), `exceptions.py` and `py.typed`. `tests/unit/` needs no SAP; `tests/integration/` needs
the SDK and a SAP system. `setup.py` defines the Cython extensions (SDK paths per OS).
Keep the public API small; underscore-prefixed modules are private.

## SAP NW RFC SDK

- The SDK is **proprietary and not redistributable.** Never commit its headers,
  libraries or binaries, and never vendor them into wheels without the user's explicit
  confirmation about licensing.
- Locate it via `SAPNWRFC_HOME` (must contain `include/` and `lib/`). Fail the build
  with a clear message if missing. Handle rpath (Linux, macOS `install_name_tool`) and
  Windows DLL search paths explicitly.
- Strings are `SAP_UC` (UTF-16). Convert at the boundary only; expose `str` and
  `bytes`/`bytearray`.
- Every SDK call returns an `RFC_RC` and fills `RFC_ERROR_INFO`. Check it every time and
  raise a typed exception from `exceptions.py`.
- Free every handle (connection, function, table, structure) deterministically: context
  managers and `close()`, with `__dealloc__` as a backstop.
- Release the GIL (`with nogil`) around blocking network calls; touch Python objects
  only with it held.
- Never share a handle between threads at the same time (Programming Guide 4.2.1):
  hold the client's lock around every use of the connection handle. Async code calls
  the sync method through `asyncio.to_thread`, never a second copy of the logic, and
  maps task cancellation to `RfcCancel`.

### References

Consult in order:

1. **Local SDK (authoritative):** headers in `$SAPNWRFC_HOME/include`, guide and release
   notes in `$SAPNWRFC_HOME/doc`. Read in place; never copy into the repo.
2. **Official SAP sources** (notes need an S-user login, so they may not be fetchable):
   [landing page](https://support.sap.com/en/product/connectors/nwrfcsdk.html),
   [7.50 Programming Guide](https://support.sap.com/content/dam/support/en_us/library/ssp/products/connectors/nwrfcsdk/NW_RFC_750_ProgrammingGuide.pdf),
   SAP Note 2573790 (installation and availability), SAP Note 2573881 (release notes).
3. **PyRFC**, inspiration only, never a source of SDK behavior or code.

Do not add other URLs without the user's approval.

## Commands

`Taskfile.yml` is the source of truth; run `task --list` to see the available tasks.
Add new workflows there. Run `task check` before declaring any task done. If the SDK is
unavailable locally, say so rather than claiming the compiled code was tested.

## Build

- `setuptools` + `Cython` (in `[build-system]`), directives `language_level=3` and
  `embedsignature=True`.
- `cibuildwheel` in CI: `windows-latest`, `macos-latest` (x86_64 + arm64),
  `ubuntu-latest` (manylinux); CPython 3.11, 3.12, 3.13+.
- Generated `.c` files and build artifacts are not committed (`.gitignore` covers them,
  plus `.venv/`, caches and `.env`).
- A test or CI step checks that `py.typed` ships in the wheel and stubs pass
  `mypy.stubtest`.

## Lint and type config

Lives in `pyproject.toml`: ruff line length 88, indent 4 spaces, docstring convention
`google`, rule set `E F W I N D UP B C4 SIM PL RUF COM812`; mypy `strict = true` on
Python 3.11; pytest `testpaths = ["tests"]` with marker `sap`. Ruff does not lint
`.pyx`; keep Cython tidy by hand (same width and indent).

## Testing

- Unit tests run without SAP: conversions, error mapping, parameter validation,
  exceptions. Mock at the SDK boundary.
- Integration tests are marked `sap`, read `DRAGONRFC_ASHOST`, `DRAGONRFC_SYSNR`,
  `DRAGONRFC_CLIENT`, `DRAGONRFC_USER` and `DRAGONRFC_PASSWD` from the environment, and
  skip cleanly when unset. Never hard-code credentials or commit `.env`.
- A bug fix comes with a regression test.

## Conventions

- [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html):
  `snake_case` functions, `PascalCase` classes, `CAPS` constants, absolute imports.
- Minimal, focused diffs. No unrequested features, options or abstractions.
- Never log or include passwords, SNC secrets or tickets in errors, repr or tests.
- Commit messages are imperative and short. Do not commit unless asked.
