#!/usr/bin/env bash
# Pull Schema — the REVERSE step: what was merged into the repository goes back into the model.
# Also runs on its own in any CI: set the PS_* variables and call it.
#
#   PS_TOKEN   WRITE token (secret), tied to this one model      required
#   PS_MODEL   model id                                          required
#   PS_URL     default https://pullschema.com
#   PS_PATH    default db   (where modelo.pullschema.json and .pullschema.json are)
#   PS_APPLY   true | false   default false = preview only (touches nothing)
#   PS_FORCE   true | false   default false = a conflict stops the run
#
# Exit codes: 0 = done (applied, previewed or nothing to do), 1 = refused (conflict, bad token, bad file).
set -euo pipefail

say()  { printf '%s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
out()  { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }

PS_URL="${PS_URL:-https://pullschema.com}"; PS_URL="${PS_URL%/}"
PS_PATH="${PS_PATH:-db}"

[ -n "${PS_TOKEN:-}" ] || fail "The token is empty. Store a WRITE token as a secret and pass it as 'token'."
[[ "${PS_MODEL:-}" =~ ^[0-9]+$ ]] || fail "'model' must be the model id (a number), got '${PS_MODEL:-}'."
case "$PS_URL" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*) ;;
  *) fail "The address must start with https:// (got '$PS_URL')." ;;
esac
[ -f "$PS_PATH/modelo.pullschema.json" ] || fail "$PS_PATH/modelo.pullschema.json not found."
[ -f "$PS_PATH/.pullschema.json" ]       || fail "$PS_PATH/.pullschema.json not found."

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
args=(-F "modelo=@$PS_PATH/modelo.pullschema.json" -F "estado=@$PS_PATH/.pullschema.json")
[ "${PS_APPLY:-false}" = true ] && args+=(-F "aplicar=1")
[ "${PS_FORCE:-false}" = true ] && args+=(-F "force=1")

code=$(curl -sS -X POST -o "$tmp/body" -w '%{http_code}' \
  -H "Authorization: Bearer $PS_TOKEN" -H "User-Agent: pullschema-import/1" \
  "${args[@]}" "$PS_URL/api/models/$PS_MODEL/git-import") || fail "Could not reach $PS_URL."

msg() { sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$tmp/body" | head -1; }

case "$code" in
  204) say "The repository has nothing new for model $PS_MODEL."; out result unchanged; exit 0 ;;
  200)
    if grep -q '"aplicado":true' "$tmp/body"; then
      say "Applied to model $PS_MODEL. The previous state was saved as a version."; out result applied
    else
      say "Preview only (set apply: true to apply):"; cat "$tmp/body"; printf '\n'; out result preview
    fi
    exit 0 ;;
  409) fail "Conflict: $(msg) (set force: true to let the repository file win)." ;;
  401|403) fail "The server refused the token (HTTP $code). It must be a WRITE token tied to model $PS_MODEL." ;;
  422) fail "The server did not accept the files: $(msg)" ;;
  *) fail "Unexpected answer (HTTP $code): $(head -c 300 "$tmp/body")" ;;
esac
