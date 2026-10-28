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
(NW RFC SDK). It is a spiritual successor to
[SAP-archive/PyRFC](https://github.com/SAP-archive/PyRFC), which is archived.

### PyRFC is inspiration only

- **PyRFC is inspiration, not a base.** Read it to learn which SDK features matter and
  how users expect to use them. Do not fork it, port it file by file, or copy its code,
  structure, API names or docstrings. `dragonrfc` is a fresh implementation with its
  own design.
- If any PyRFC code is ever reused, it needs the user's explicit approval first, plus
  license compliance (Apache 2.0) and attribution.
- **Do not freeze at PyRFC's feature set.** PyRFC was archived against an older SDK.
  Check the current NW RFC SDK release notes and headers for features added since
  (new APIs, protocols, SNC/TLS and auth options, platform and OS support, ICU or
  Unicode changes, deprecations and removals) and support them where feasible.
- Record what you checked and decided (supported, deferred, not feasible, with the
  reason) in `docs/sdk-features.md`, so the decision is not repeated.
- Never invent SDK behavior from PyRFC or memory. Verify against the SDK headers and
  the official documentation.

## Non-negotiable foundations

1. **Fully typed (PEP 561).** Ship `py.typed` and a `.pyi` stub for every compiled
   module. Stubs are the public typing contract and must match the Cython code.
2. **Compiled for Windows, macOS and Linux.** Wheels are built per platform (see
   [Build](#build)). Never write code that only works on one OS.
3. **Python >= 3.11.** Set `requires-python = ">=3.11"`. Do not add compatibility shims
   for older versions.
4. **Google-style docstrings** on every exposed function, class, method and module
   (`Args:`, `Returns:`, `Raises:`, `Example:` as appropriate).
5. **Tests with pytest.**
6. **uv** is the only package manager. Do not use `pip install`, `poetry` or `conda`
   in docs, scripts or CI. Commit `uv.lock`.
7. **ruff** for linting and formatting, Google Python Style:
   - line length 88, indent width 4, indent style space
   - docstring convention `google`
8. **mypy** for static type checking, in strict mode.
9. **[Task](https://taskfile.dev/)** is the task automation tool. Every recurring
   workflow (setup, format, lint, type check, test, build) is a task in `Taskfile.yml`.
   CI and docs call `task <name>`, not raw commands; no Makefiles or ad-hoc scripts.
10. **EditorConfig leads file formatting.** `.editorconfig` is the source of truth for
    indentation, line endings, charset, final newline and trailing whitespace. Tool
    configs (ruff, etc.) must agree with it, never override it.
11. **Git** is the version control tool. Keep a `.gitignore` covering build artifacts,
    generated `.c` files, `.venv/`, caches and `.env`; never commit the SAP SDK.
12. **GitHub** is the remote and the CI/CD platform. Pipelines are GitHub Actions
    workflows in `.github/workflows/`; they call `task <name>`, run on Linux, macOS and
    Windows, and build wheels with `cibuildwheel`. The SAP SDK reaches CI only through
    secrets or private artifacts. Use the `gh` CLI for PRs and issues.
13. **Linting must pass on every change.** `task format:check` and `task lint:check`
    report zero issues. No blanket `# noqa`; silence a rule only per line, with its
    code and a reason.
14. **Type checking must pass on every change.** `task typecheck` and `task stubtest`
    report zero errors.
15. **All tests must pass on every change.** `task test` is green, and so is
    `task test:sap` when the SDK and a SAP system are available. Never skip, delete or
    weaken a test to make a change pass. A change that fails any of 13-15 is not done
    and is not merged; CI enforces this on every push and PR.
16. **Every file starts with the SPOT header** defined in `.vscode/spot.code-snippets`
    (`spotheader` snippet). Use the YAML variant (with `---` and
    `# code: language=yaml`) for YAML files, and the generic one for everything else
    that takes `#` comments (`.py`, `.pyx`, `.pxd`, `.pyi`, `.toml`, `.editorconfig`,
    `.gitignore`, ...). Keep the year as the file's creation year. Files with another
    comment syntax carry the same text in that syntax (e.g. `<!-- -->` in Markdown);
    files without comments (JSON, `py.typed`, `uv.lock`) are exempt. A shebang, if
    any, stays on line 1, above the header.
17. **Every Python module has a module docstring** right after the SPOT header, in
    this format:

    ```python
    """Short module title.

    Module explanation covering:
    - Module overview
    - Module API
    - Examples of usage.
    """
    ```

    This applies to `.py`, `.pyx` and `.pyi` files, including `__init__.py` and tests.
    Keep it in sync with the module's actual API.

## Layout

```text
dragonrfc/
├── AGENTS.md
├── pyproject.toml          # metadata, build, ruff, mypy, pytest config
├── uv.lock
├── Taskfile.yml            # task automation (single entry point for workflows)
├── .editorconfig           # source of truth for file formatting
├── .gitignore
├── setup.py                # Cython extension definitions (SDK paths per OS)
├── src/dragonrfc/
│   ├── __init__.py         # public API re-exports, __all__, __version__
│   ├── py.typed
│   ├── _cinsdk.pxd         # extern declarations from sapnwrfc.h
│   ├── _core.pyx           # Cython implementation
│   ├── _core.pyi           # stub for _core
│   └── exceptions.py       # typed exception hierarchy
├── tests/
│   ├── unit/               # no SAP SDK or system needed
│   └── integration/        # need SDK + reachable SAP system (marker: sap)
└── .github/workflows/      # CI: lint, mypy, tests, cibuildwheel
```

Keep the public API small. Underscore-prefixed modules are private.

## SAP NW RFC SDK

- The SDK is **proprietary and not redistributable**. Never commit SDK headers,
  libraries or `libsapnwrfc` binaries, and never vendor them into wheels without
  explicit confirmation from the user about licensing.
- Locate it through the `SAPNWRFC_HOME` environment variable (must contain `include/`
  and `lib/`). Fail the build with a clear message if it is missing.
- Per OS: Linux `libsapnwrfc.so` / `libicu*`, macOS `libsapnwrfc.dylib`
  (`install_name_tool` / rpath), Windows `sapnwrfc.dll` + `.lib`. Handle rpath and DLL
  search paths explicitly.
- SDK strings are `SAP_UC` (UTF-16). Convert at the boundary only; expose `str` and
  `bytes`/`bytearray` in Python.
- Every SDK call returns an `RFC_RC` and fills `RFC_ERROR_INFO`. Check it every time and
  raise a typed exception from `exceptions.py`. Never ignore a return code.
- Free every SDK handle (connection, function, table, structure) deterministically.
  Provide context managers and `close()`, and release in `__dealloc__` as a backstop.
- Release the GIL (`with nogil`) around blocking network calls, and only touch Python
  objects with it held.

## Commands

```bash
task setup                       # uv sync: install deps + build extension (dev mode)
task format                      # uv run ruff format .
task lint                        # uv run ruff check . --fix
task typecheck                   # uv run mypy
task test                        # uv run pytest (unit tests)
task test:sap                    # uv run pytest -m sap (needs SDK + SAP system)
task build                       # uv build: sdist + wheel
task stubtest                    # mypy.stubtest: .pyi stubs match the compiled module
task format:check                # ruff format --check (CI)
task lint:check                  # ruff check without fixes (CI)
task wheels                      # cibuildwheel platform wheels (needs SAPNWRFC_HOME)
task check                       # format + lint + typecheck + stubtest + test
```

Tasks wrap `uv run ...`; `uv` stays the package manager. Add new workflows to
`Taskfile.yml` and keep this list in sync.

Run `task check` before declaring any task done. If the SDK is not
available locally, say so explicitly rather than claiming the compiled code was tested.

## Build

- Backend: `setuptools` + `Cython` (declared in `[build-system]`), with
  `cython` directives `language_level=3`, `embedsignature=True`.
- Wheels: `cibuildwheel` in CI for `windows-latest`, `macos-latest` (x86_64 + arm64)
  and `ubuntu-latest` (manylinux), CPython 3.11, 3.12, 3.13+. The SDK is supplied to CI
  via a private secret/artifact, never from the repo.
- Generated `.c` files and build artifacts are not committed.

## Typing rules

- `mypy` runs with `strict = true`. No unjustified `# type: ignore`; add the error code
  and a reason when unavoidable.
- Every `.pyx` public symbol has a matching entry in the `.pyi`. When you change a
  signature in one, change the other in the same commit.
- Add a test (or CI step) that checks `py.typed` ships in the wheel and that stubs pass
  `mypy.stubtest`.
- Use precise types (`TypedDict`, `Literal`, `Protocol`, `Sequence`/`Mapping` for
  inputs). Avoid `Any` in the public API.

## Docstrings

Google style, enforced by ruff (`pydocstyle` rules, `convention = "google"`):

```python
def call(self, name: str, **params: object) -> dict[str, object]:
    """Invokes a remote-enabled function module.

    Args:
        name: Function module name, e.g. ``"STFC_CONNECTION"``.
        **params: Import, changing and table parameters.

    Returns:
        Export, changing and table parameters returned by the system.

    Raises:
        RFCCommunicationError: If the network call fails.
        RFCABAPError: If the function raises an ABAP exception.
    """
```

Docstrings in `.pyx` files must follow the same format (they feed `help()` and IDEs).
Private helpers need a docstring only when the behavior is not obvious.

## Ruff / mypy / pytest config (in `pyproject.toml`)

```toml
[tool.ruff]
line-length = 88
indent-width = 4

[tool.ruff.format]
indent-style = "space"
docstring-code-format = true

[tool.ruff.lint]
select = ["E", "F", "W", "I", "N", "D", "UP", "B", "C4", "SIM", "PL", "RUF"]

[tool.ruff.lint.pydocstyle]
convention = "google"

[tool.mypy]
strict = true
python_version = "3.11"

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = ["sap: needs the NW RFC SDK and a reachable SAP system"]
```

Ruff does not lint `.pyx`; keep Cython code tidy by hand (same line length, 4 spaces,
`cython-lint` optionally).

## EditorConfig

`.editorconfig` at the repo root (`root = true`) leads formatting for all files. Ruff
does not read it, so the `[tool.ruff]` values above must mirror it. Change
`.editorconfig` first, then align the tool configs.

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 4
max_line_length = 88

[*.{yml,yaml,toml,json}]
indent_size = 2

[*.md]
trim_trailing_whitespace = false

[*.bat]
end_of_line = crlf
```

Do not hand-format against it: if a file disagrees, fix the file (or the config), not
the other way around.

## Testing

- Unit tests must run without SAP: test conversions, error mapping, parameter
  validation and the exceptions module. Mock at the SDK boundary where needed.
- Integration tests are marked `sap` and read connection data from environment
  variables (`DRAGONRFC_ASHOST`, `DRAGONRFC_SYSNR`, `DRAGONRFC_CLIENT`,
  `DRAGONRFC_USER`, `DRAGONRFC_PASSWD`). Skip them cleanly when unset. Never hard-code
  credentials or commit `.env` files.
- A bug fix comes with a regression test.

## Conventions

- Follow the [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html):
  `snake_case` functions, `PascalCase` classes, `CAPS` constants, absolute imports.
- Keep the diff minimal and focused. No unrequested features, options or abstractions.
- Never log or include passwords, SNC secrets or tickets in errors, repr or tests.
- Commit messages are imperative and short. Do not commit unless asked.
