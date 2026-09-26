---
paths: "**/*.{sh,bash}"
---

# Bash Rules

Loaded when editing shell scripts. Universal rules live in `constitution.md`. The gitflow scripts are the primary audience; consumer projects rarely author bash.

## I. Check exit codes explicitly, not through a pipe (Zero Tolerance)

**Capture and check a command's return code yourself rather than relying on `set -o pipefail`.** In `if ! cmd | filter` or `cmd | filter || handle`, the exit status is the filter's — typically 0 for any input — so the command's failure is swallowed and the branch falls through. `pipefail` covers it locally, but the next editor removes the safety net invisibly, and macOS bash 3.2 has gaps of its own.

Keep cosmetic filters (`| sed 's/^/  /' >&2`) out of an error-check condition entirely.

```bash
# Capture, then format on the success path
FETCH_OUT=$(git fetch origin main 2>&1) || {
    printf '%s\n' "$FETCH_OUT" >&2
    echo "fetch failed" >&2
    exit 6
}

# Or drop the filter and let the command's own output stand
if ! git fetch origin main; then
    echo "fetch failed" >&2
    exit 6
fi

# Or use PIPESTATUS where the filter genuinely belongs
git fetch origin main 2>&1 | sed 's/^/  /' >&2
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "fetch failed" >&2
    exit 6
fi
```

Scripts already carrying `set -eo pipefail` (`work.sh`, `merge.sh`) are grandfathered, but new pipes added to them still use the explicit check. A new script may set `pipefail` too — it is the safety net, and the explicit check is still the design.

## I-b. `grep` is ugrep, and it SKIPS files containing a NUL byte

Claude Code replaces `grep` with a shell function (from `~/.claude/shell-snapshots/`)
that runs **ugrep**, adding flags you did not type:

```
-G --ignore-files --hidden -I --exclude-dir=.git --exclude-dir=.svn …
```

**`-I` means "ignore binary files", and a single NUL byte makes a file binary.**
Such a file is not searched at all — so a pattern that is present reports as
absent.

**The tell is NO OUTPUT, not a zero.** That distinction is the whole defence:

```bash
grep -c pattern present.txt    # -> 1     found
grep -c pattern absent.txt     # -> 0     genuine miss, exit 1
grep -c pattern hasnul.txt     # ->       NOTHING. file skipped, never searched
```

**So never pipe grep through a counter when the question is "is it there".**
`grep -o … | wc -l` turns "skipped" into `0`, destroying the one signal that
distinguishes a miss from a non-search:

```bash
grep -o "$pat" f | wc -l    # WRONG — prints 0 for both cases
grep -c "$pat" f            # right — empty output means skipped
```

**`-a` overrides it** (verified), which is why the legacy-source rules prescribe
`LC_ALL=C grep -a`. Keep using it there.

**This is not exotic.** Real generated artifacts carry NUL bytes as delimiters —
notably **TanStack Start's SSR HTML**, whose dehydrated router state contains
them (`{i:"\x00route\x00route"}`). So verifying a served page with bare `grep`
silently reports nothing rendered, on a page that rendered perfectly.

For content verification on generated output, use one of:

```bash
/usr/bin/grep -c "$pat" file    # the real grep, no injected flags
rg -c "$pat" file               # ripgrep: prints "0"/exits 1, does not skip
python3 -c "print(open('file',encoding='utf-8').read().count('$pat'))"
```

The same reasoning as the mixed-encoding rule in the legacy handoffs, one layer
down: **a tool that declines to read a file reports the same zero as a tool that
read it and found nothing.** Whenever a zero would change a conclusion, confirm
the file was actually searched.

## II. Target macOS bash 3.2

Apple does not ship anything newer, so every script here must run on it.

Use `tr '[:lower:]' '[:upper:]'` rather than `${VAR^^}`. Use parallel indexed arrays or process substitution rather than `declare -A`. Use `while IFS= read -r line; do …; done < <(cmd)` rather than `mapfile` or `readarray`. Guard `shopt -s inherit_errexit` with `2>/dev/null || true` if you need it at all, and do not rely on its semantics — it is a silent no-op on 3.2.

`[[ … =~ … ]]` with `BASH_REMATCH` works on 3.2 and is fine.

Prefer POSIX-ish constructs where a 4.x feature buys nothing. Check `/bin/bash --version` when you start on a script: 3.2 is the target whatever it reports, and a 4.x or 5.x shell on your machine means your local run will accept things that break for everyone else.

## III. `set -e` coverage gaps

`set -e` is not a complete strategy. It misses four things:

- **A pipeline without `pipefail`** — see §I.
- **`local var=$(cmd)`** — the assignment masks the exit code. Split it: `local var; var=$(cmd) || return $?`.
- **`$()` used directly as an argument** — errors inside it do not propagate. Capture into a variable first, then pass the variable.
- **`cmd && other_cmd` as a function's last statement** — the function returns non-zero when `cmd` fails, but `set -e` does not fire if the call site checks with `if`. Write it as `if cmd; then other_cmd; fi` and return explicitly.

ERR traps are not inherited into subshells or functions without `set -E`.

When in doubt, write `if ! cmd; then handle; fi`.

## IV. Shellcheck

Run `shellcheck -x <script>` before committing any meaningful bash change. `-x` follows sourced files; without it every `source` line reports SC1091. A `source "$SCRIPT_DIR/…"` reports SC1091 even with `-x`, because the path is not resolvable statically — that one is noise.

Treat an error or warning as a defect and a note as judgment. Suppress a genuine false positive with `# shellcheck disable=SCxxxx` and a one-line reason naming why it does not apply.

**SC2207 advises `mapfile`, which §II forbids on bash 3.2.** Split with `while IFS= read -r` instead, or suppress it with that reason — never take the suggestion.

## V. BSD awk vs gawk

macOS ships BSD awk and Linux CI ships gawk, so a script can pass CI and die on the developer's machine.

**Never pass a value that may contain a newline through `awk -v`.** BSD awk rejects it with `awk: newline in string` and exits non-zero; gawk accepts it silently. Pass a file path instead and read it inside awk with `getline`:

```bash
awk -v entry_file="/tmp/entry.md" '
    BEGIN {
        entry = ""
        while ((getline line < entry_file) > 0) {
            entry = entry (entry == "" ? "" : "\n") line
        }
        close(entry_file)
    }
    {...}
' input.txt
```

Stick to POSIX awk features — `gensub`, `asorti`, `length(array)` and `\b` anchors are gawk extensions that fail only on macOS. If one is essential, gate on `command -v gawk` and invoke `gawk` explicitly. Test multi-line inputs on macOS before committing; Linux CI cannot catch this class.
