#!/usr/bin/env bash
# Regression suite for block-db-commands.sh — postgres-drizzle.md, commands that
# CHANGE a database never run on Claude's own judgment.
#
# This guard is default-DENY, so the cases that matter most are the ALLOWS: a false
# block here stops ordinary `npm test` / `npm run build` work dead.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-db-commands.sh"
fail=0
tmpout=$(mktemp); trap 'rm -f "$tmpout"' EXIT

decision(){
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "${2:-Bash}" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
t(){ d=$(decision "$2" "${4:-Bash}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL ($d, want $1) — $3"; fail=1; fi; }

echo "MUST DENY — commands that change a database, without approval:"
t deny 'npm run db:migrate'           'db:migrate'
t deny 'npm run db:push'              'db:push (never allowed at all)'
t deny 'npx drizzle-kit migrate'      'drizzle-kit direct'
t deny 'npx drizzle-kit push'         'drizzle-kit push'
t deny 'pnpm db:migrate'              'runner without a run subcommand'
t deny './node_modules/.bin/drizzle-kit push' 'path-qualified binary'
t deny 'cd apps/shared && npm run db:migrate' 'chained after cd'

echo "MUST ALLOW — db:generate writes files and touches no database:"
t allow 'npm run db:generate'                 'db:generate needs no approval'
t allow 'npm run db:generate -- --name="add user table"' 'db:generate with a name'
t allow 'npx drizzle-kit generate'            'drizzle-kit generate direct'
t allow 'npx drizzle-kit generate --custom'   'drizzle-kit generate --custom'

echo "MUST ALLOW — approved runs:"
t allow 'SKIP_DB_GUARD=1 npm run db:migrate'  'approved db:migrate'
t allow 'SKIP_DB_GUARD=1 npx drizzle-kit push' 'approved drizzle-kit push'

echo "MUST ALLOW — ordinary work (a false block here stops everything):"
t allow 'npm test'                    'npm test'
t allow 'npm run build'               'npm run build'
t allow 'npm ci'                      'npm ci'
t allow 'psql "$DATABASE_URL" -c "SELECT 1"' 'a read-only psql query'
t allow 'git status'                  'git status'
t allow 'npm run db:migrate' 'non-Bash tool is out of scope' Read

echo "MUST ALLOW — heredoc bodies are data being written, not commands being run:"
t allow 'cat > doc.md <<EOF
run npm run db:migrate to apply it
EOF' 'heredoc body mentioning db:migrate'
t allow 'cat > doc.md <<EOF
npx drizzle-kit push
EOF' 'heredoc body mentioning drizzle-kit'

echo "MUST STILL DENY — a real command outside the heredoc:"
t deny 'cat > doc.md <<EOF
harmless text
EOF
npm run db:migrate' 'command after a heredoc'
t deny 'cat > doc.md <<EOF
mentions drizzle-kit here
EOF
npx drizzle-kit push' 'command after a heredoc that also mentions it'

echo "MUST ALLOW — naming a migration command is data, not invoking it:"
t allow 'grep -rn db:migrate project-documentation/'  'grepping for db:migrate'
t allow 'rg "drizzle-kit push" --glob "*.md"'         'ripgrep for drizzle-kit push'
t allow 'echo "run npm run db:migrate to apply it" > doc.md' 'prose naming db:migrate'
t allow 'sed -i "" "s/db:push/db:migrate/" doc.md'    'sed rewriting the strings'

echo "MUST ALLOW — reads through psql (the documented inspection path):"
t allow 'psql "$DATABASE_URL" -c "SELECT * FROM inventory"'   'plain SELECT'
t allow 'psql "$DATABASE_URL" -c "SELECT updatedat FROM part"' 'SELECT of a column named updatedat'
t allow 'psql "$DATABASE_URL" -c "SELECT createdat, deletedat FROM row"' 'columns embedding create/delete'
t allow 'psql "$DATABASE_URL" -c "\\dt"'                       'catalog listing'
t allow 'psql "$DATABASE_URL" -c "SELECT count(*) FROM qbitemdtl"' 'aggregate read'

echo "MUST ALLOW — naming psql is data, not invoking it:"
t allow 'echo "use psql to INSERT rows" > doc.md'              'prose naming psql and INSERT'
t allow 'grep -rn psql project-documentation/'                 'grepping for psql'
t allow 'psql "$DATABASE_URL" -c "SELECT 1" | grep -f pat.txt' 'read piped into grep -f'
t allow 'rg "INSERT INTO" --glob "*.sql"'                      'ripgrep for INSERT'

echo "MUST DENY — hand-run writes (they land on one branch only):"
t deny '/opt/homebrew/bin/psql "$U" -c "DELETE FROM t"'        'absolute path to psql'
t deny 'PGPASSWORD=x psql "$U" -c "UPDATE t SET a=1"'          'env-prefixed invocation'
t deny 'psql "$DATABASE_URL" -c "INSERT INTO firmware VALUES (1)"' 'INSERT'
t deny 'psql "$DATABASE_URL" -c "UPDATE part SET x = 1"'           'UPDATE'
t deny 'psql "$DATABASE_URL" -c "DELETE FROM part WHERE id = 1"'   'DELETE'
t deny 'psql "$DATABASE_URL" -c "TRUNCATE part"'                   'TRUNCATE'
t deny 'psql "$DATABASE_URL" -c "ALTER TABLE part ADD COLUMN y int"' 'ALTER'
t deny 'psql "$DATABASE_URL" -c "CREATE INDEX ON part (id)"'       'CREATE'
t deny 'psql "$DATABASE_URL" -c "GRANT SELECT ON part TO app_user"' 'GRANT'
t deny 'psql "$DATABASE_URL" -f seed.sql'                          'script file (contents invisible)'
t allow 'SKIP_DB_GUARD=1 psql "$DATABASE_URL" -c "INSERT INTO firmware VALUES (1)"' 'approved hand-run write'

echo "DENY PAYLOAD MUST BE VALID JSON (a malformed deny is silently discarded):"
jsonok(){
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null > "$tmpout"
  if [ ! -s "$tmpout" ]; then echo "  ✗ FAIL — expected a deny, got allow: $1"; fail=1; return; fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmpout" 2>/dev/null
    then echo "  ✓ parses: $1"
    else echo "  ✗ FAIL — MALFORMED deny payload: $1"; fail=1; fi; }
jsonok 'npm run db:migrate'
jsonok 'npx drizzle-kit migrate --config="drizzle.config.ts"'

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  printf '%s' "$p" | "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

exit "$fail"
