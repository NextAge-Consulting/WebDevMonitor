---
paths: "**/*.py"
---

# Python Rules

Loaded when editing Python. Universal rules live in `constitution.md`.

## I. Python Quality (Zero Tolerance)

**Commit no type errors or lint violations.** The pre-commit hook enforces it, and Ruff and type-checker diagnostics are authoritative — quality failures, not suggestions.

Fix the type issue rather than writing `# type: ignore`, fix the lint issue rather than `# noqa`, and give values real types rather than `Any`.

F401 (unused import) and F841 (unused variable) mean delete it, after checking for indirect usage. E501 means reformat. A type mismatch gets fixed at its source.

## II. Logging

**Use the `logging` module with structured loggers.** A PreToolUse hook blocks `print()` in production code.

```python
import logging
logger = logging.getLogger(__name__)

logger.info("Processing request", extra={"user_id": user_id})
logger.error("Request failed", exc_info=True, extra={"request_id": req_id})
logger.debug("Debug context", extra={"data": data})
```

Watch it with `tail -f logs/app.log`. Server lifecycle is governed by `dev-server.md`.

## III. Naming

`snake_case` for variables and functions, `PascalCase` for classes, `UPPER_SNAKE_CASE` for constants.

## IV. Timezone-Aware Code — Python Patterns

Constitution §VI carries the principle. In Python:

Call `datetime.now(tz)` with an explicit timezone rather than a bare `datetime.now()`. Use `datetime.now(timezone.utc)` rather than the deprecated `datetime.utcnow()`. Derive a user-facing "today" from a timezone-aware `datetime.now(tz)` rather than `date.today()`. Write timezone-aware datetimes to the database, into a `TIMESTAMPTZ` column.

## V. Optional Handling

Check `is None` explicitly — a truthy check swallows valid falsy values:

```python
if user is not None:
    process(user)
```

## VI. Type Narrowing

Narrow with `isinstance` and type guards:

```python
from typing import TypeGuard

def is_valid_user(obj: object) -> TypeGuard[User]:
    return isinstance(obj, User) and obj.email is not None
```

## VII. Async

**Never block the event loop.** Use `await asyncio.sleep()` rather than `time.sleep()`, `httpx.AsyncClient` or `aiohttp` rather than `requests.get()`, `aiofiles` rather than sync file I/O, and an async driver such as asyncpg rather than a blocking database call.

Use a `TaskGroup` (3.11+) where one task failing should cancel the rest; `asyncio.gather` is still right where it should not. Close resources on SIGTERM/SIGINT:

```python
async with asyncio.TaskGroup() as tg:
    task1 = tg.create_task(fetch_user(user_id))
    task2 = tg.create_task(fetch_settings(user_id))

async def shutdown():
    await db.close()
    await scheduler.shutdown()
```

## VIII. FastAPI

Inject dependencies through `Depends`, and define request bodies as Pydantic models:

```python
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        yield session

@app.get("/users")
async def get_users(db: AsyncSession = Depends(get_db)):
    ...

class UserCreate(BaseModel):
    email: str = Field(..., description="User email")
    name: str = Field(..., min_length=1)
```

## IX. Code Standards

Python 3.11+, with type hints on every function.

## X. Setup and Commands

Python LSP needs both Claude Code's official plugin and the pyright binary (constitution §IX). One-time per machine:

```bash
/plugin install pyright-lsp@claude-plugins-official
npm install -g pyright        # or: pip install pyright
```

Verify with `which pyright-langserver` returning a path and `/plugin list` showing `pyright-lsp`. With either missing, LSP for Python is dead — fall back to the CLI. To verify end to end, run `documentSymbol`, `hover` and `findReferences` against a known-good file; `project-documentation/claude-code-setup.md` §Python holds the fixture and expected results.

The CLI always works, and is what CI and pre-commit run: `pyright` (or `mypy .` where the project standardizes on mypy), `ruff check .`, `ruff format .`, `python -m pytest`.

### Pyright configuration

**Put the config at the repo root** — `pyrightconfig.json`, or `[tool.pyright]` in the root `pyproject.toml`. `[tool.ruff]` goes in `pyproject.toml`.

Pyright reads config only from the directory it is launched in, which for editors and the LSP plugin is the repo root. In a repo whose Python lives in `services/*/` or `packages/*/`, a `[tool.pyright]` block in a subdirectory `pyproject.toml` is never read and is silently inert: pyright falls back to the system interpreter with no `site-packages`, then false-flags modern stdlib symbols like `datetime.UTC` and reports every import as unresolvable. A correct-looking block in the wrong file reads as configured and is not.

Verify with `pyright --outputjson | jq .summary` and check that `filesAnalyzed` matches the real file count — green because nothing was looked at is not green.

Scope `include` to the subtree roots rather than enumerating `src` and `tests`, which silently exempts operational code in `scripts/` and `deploy/` from ever being checked.

With multiple venvs under one root, pyright takes one project-level `venv`, so give each subtree an `executionEnvironments` entry whose `extraPaths` carries its `src` plus its venv's `site-packages`.

## XI. Dependency & Environment Discipline

Two kinds of dependency, two opposite rules — one is a library the code needs, the other is the gate that judges the code.

**Runtime dependencies are per-service and independent.** One venv per service or package, each with its own `pyproject.toml` and lockfile. Services that do not import each other have no reason to agree on their libraries.

**Shared dev tooling is pinned exact and identical in every service** — ruff, the type checker, the test runner, anything used by more than one.

Write `ruff==X.Y.Z`, never `>=`, for any linter, formatter or type checker: with a floor, each service locks whatever was current the day it last resolved, and a rule added in a patch release then fails untouched code in one service only. Bump the pin in every service in the same change, or the split silently re-opens.

Pin the interpreter with `.python-version` in every service — `requires-python = ">=3.11"` is a floor, not a pin, and without the file `uv` picks any compatible interpreter, landing one service on 3.13 and its sibling on 3.11 on the same machine. Match that pinned interpreter to the deploy target.

**Do not reach for a `uv` workspace to fix drift between independent services** — the pinning rules above are what fixes it. A workspace is right for genuinely interconnected packages, which is what uv scopes it to: one lockfile, one venv, and members wanting their own virtual environment explicitly excluded. For independent services that shared venv is actively harmful: uv cannot stop service A importing a dependency only service B declares, so it passes every local test and fails wherever A deploys alone.
