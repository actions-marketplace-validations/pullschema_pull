#!/usr/bin/env bash
# Pull Schema — the step behind the action. Also runs on its own in any CI
# (GitLab, Azure DevOps, Jenkins): set the PS_* variables and call it.
#
#   PS_TOKEN    machine token (secret)            required
#   PS_MODEL    model id                          required
#   PS_URL      default https://pullschema.com
#   PS_PATH     default db
#   PS_DIALECT  empty = the model's own
#   PS_MODE     offline | online                  default offline
#   PS_FORCE    true | false                      default false
#   PS_LAYOUT   classico | simples | ssdt | redgate — first run only; after
#               that the repository's .pullschema.json remembers it
#
# Exit codes: 0 = done (changed or not), 1 = the server refused or failed.
set -euo pipefail

say()  { printf '%s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
out()  { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }

PS_URL="${PS_URL:-https://pullschema.com}"; PS_URL="${PS_URL%/}"
PS_PATH="${PS_PATH:-db}"
PS_MODE="${PS_MODE:-offline}"

[ -n "${PS_TOKEN:-}" ] || fail "The token is empty. Store it as a secret (e.g. PULLSCHEMA_TOKEN) and pass it as 'token'."
[[ "${PS_MODEL:-}" =~ ^[0-9]+$ ]] || fail "'model' must be the model id (a number), got '${PS_MODEL:-}'."
# The token would travel in clear over plain http. Only a local test server is exempt.
case "$PS_URL" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*) ;;
  *) fail "The address must start with https:// (got '$PS_URL')." ;;
esac
case "$PS_MODE" in offline|online) ;; *) fail "'mode' is 'offline' or 'online', got '$PS_MODE'." ;; esac

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$PS_PATH"

args=(-F "dbms=${PS_DIALECT:-}")
[ "$PS_MODE" = online ] && args+=(-F "modo=quente")
[ "${PS_FORCE:-false}" = true ] && args+=(-F "force=1")
[ -n "${PS_LAYOUT:-}" ] && args+=(-F "layout=$PS_LAYOUT")
# What the repository already has is the left side of the comparison: the
# migration is the difference between it and the model as it is now.
[ -f "$PS_PATH/modelo.pullschema.json" ] && args+=(-F "modelo=@$PS_PATH/modelo.pullschema.json")
[ -f "$PS_PATH/.pullschema.json" ]       && args+=(-F "estado=@$PS_PATH/.pullschema.json")

code=$(curl -sS -X POST -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' \
  -H "Authorization: Bearer $PS_TOKEN" -H "User-Agent: pullschema-action/1" \
  "${args[@]}" "$PS_URL/api/models/$PS_MODEL/git.zip") || fail "Could not reach $PS_URL."

header() { grep -i "^$1:" "$tmp/headers" | head -1 | cut -d' ' -f2- | tr -d '\r' || true; }

case "$code" in
  204)
    say "The model did not change since what the repository has. Nothing to do."
    out changed false; out migration ''; out manual-steps 0
    exit 0 ;;
  200) ;;
  401|403) fail "The server refused the token (HTTP $code). Check that it is valid, not revoked, and that its owner can see model $PS_MODEL." ;;
  404) fail "Model $PS_MODEL not found at $PS_URL (HTTP 404)." ;;
  *)   fail "HTTP $code: $(head -c 800 "$tmp/body")" ;;
esac

# A table that left the model has to leave the repository too: the server
# lists the folders it owns (this layout's and the previous one's), and each
# one is checked again here before rm -rf — never absolute, never "..", never
# a dot-folder, never the numbered migrations.
limpar="$(header x-pullschema-limpar)"
if [ -z "$limpar" ]; then limpar="schema"; fi
IFS='|' read -r -a pastas <<< "$limpar"
for d in "${pastas[@]}"; do
  case "$d" in
    ''|/*|*..*|.*|*/.*|migrations|migrations/) printf '::warning::Refused to clean folder "%s".\n' "$d" ;;
    migrations/*) [ "$d" = "migrations/repetiveis" ] && rm -rf "${PS_PATH:?}/$d" ;;
    *) rm -rf "${PS_PATH:?}/$d" ;;
  esac
done
unzip -oq "$tmp/body" -d "$PS_PATH"

migration="$(header x-pullschema-migracao)"
manual="$(header x-pullschema-passos-manuais)"; manual="${manual:-0}"
tables=$(unzip -Z1 "$tmp/body" | grep -c '\.sql$' || true)

say "Model $PS_MODEL pulled into $PS_PATH/: $tables SQL file(s)${migration:+, migration $migration}."
[ "$manual" != 0 ] && printf '::warning::%s change(s) cannot be made by command on this database — see the comments marked in %s.\n' "$manual" "${migration:-the migration}"

out changed true
out migration "$migration"
out manual-steps "$manual"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo 'body<<PULLSCHEMA_EOF'
    echo "Data model changes pulled from [Pull Schema]($PS_URL) — model \`$PS_MODEL\`."
    echo
    if [ -n "$migration" ]; then
      echo "- **Migration:** \`$PS_PATH/migrations/$migration\`"
    else
      echo "- **No migration:** the change needs no DDL (a description, a diagram position)."
    fi
    echo "- **Current state:** $tables SQL file(s) under \`$PS_PATH/\`"
    if [ "$manual" != 0 ]; then
      echo
      echo "> **$manual change(s) the database cannot make by command.** They are explained, commented, inside the migration — review them before merging."
    fi
    echo
    echo "Do not edit a migration after it ran: Flyway checks each applied file's checksum. To correct one, change the model; the next run generates the fix."
    echo 'PULLSCHEMA_EOF'
  } >> "$GITHUB_OUTPUT"
fi
