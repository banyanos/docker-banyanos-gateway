#!/usr/bin/env bash
# =============================================================================
# Bump the SilvaEngine commit pins in requirements-silvaengine.txt
#
# Every private repo in requirements-silvaengine.txt is pinned to a 40-char
# commit SHA, and the trailing "# <branch>" comment on each line records the
# branch that pin tracks (no comment = main; pip ignores the comment). This
# script resolves the current head of each tracked branch with
# `git ls-remote`, rewrites the pins that moved, refreshes the date in the
# header comment, and prints the commits each bump brings in.
#
# A changed pin changes requirements-silvaengine.txt, which busts the Docker
# pip layer cache, so the next `docker compose ... build gateway` installs the
# new commits (no --no-cache needed).
#
# Usage:
#   bash scripts/bump_silvaengine.sh                 # bump every repo on its tracked branch
#   bash scripts/bump_silvaengine.sh --dry-run       # show what would change, write nothing
#   bash scripts/bump_silvaengine.sh --staging       # switch repos to staging (main where none exists)
#   bash scripts/bump_silvaengine.sh --dev           # switch repos to dev (main where none exists)
#   bash scripts/bump_silvaengine.sh --main          # switch everything back to main
#   bash scripts/bump_silvaengine.sh --branch NAME   # any other branch (e.g. prod)
#   bash scripts/bump_silvaengine.sh --only silvaengine_gateway --staging
#   bash scripts/bump_silvaengine.sh --build         # bump, then build + recreate gateway
#   bash scripts/bump_silvaengine.sh --build --ddb   # same, with the DynamoDB Local overlay
#
# deploy.sh runs this script for you (DynamoDB Local mode): `--bump` means
# --main, `--bump=dev` / `--bump=staging` switch branches. Run it directly with
# no branch option to bump each repo on its recorded branch, or with --build for
# the cloud-DynamoDB compose path.
#
# Changelogs come from local clones under SILVAENGINE_SRC (default
# ../../silvaengine, i.e. gitrepo/silvaengine beside banyanos), fetched first;
# repos without a local clone get a GitHub compare URL instead.
#
# Fail-closed: if any selected repo cannot be resolved, nothing is written and
# the script exits 1. Nothing is committed: review the diff, then commit it so
# the bump can be reverted with `git revert`.
#
# Compatibility: bash 3.2+, needs git and SSH read access to every repo.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

DEPLOY_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$DEPLOY_DIR"

REQ_FILE="requirements-silvaengine.txt"
SILVAENGINE_SRC=${SILVAENGINE_SRC:-"$DEPLOY_DIR/../../silvaengine"}
GITHUB_OWNER="ideabosque"
DEFAULT_BRANCH="main"

BRANCH=""
ONLY=""
DRY_RUN=0
BUILD=0
DDB=0

usage() { sed -n '/^# Usage:/,/^# Compatibility:/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) [ $# -ge 2 ] || die "--branch needs a value"; BRANCH="$2"; shift ;;
    --branch=*) BRANCH="${1#--branch=}" ;;
    --main|--dev|--staging) BRANCH="${1#--}" ;;
    --only) [ $# -ge 2 ] || die "--only needs a value"; ONLY=",$2,"; shift ;;
    --only=*) ONLY=",${1#--only=}," ;;
    --dry-run) DRY_RUN=1 ;;
    --build) BUILD=1 ;;
    --ddb) DDB=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ -f "$REQ_FILE" ] || die "$REQ_FILE not found in $DEPLOY_DIR"
command -v git >/dev/null || die "git is required"

# "repo sha branch" for each pinned line, in file order.
PINS=$(tr -d '\r' < "$REQ_FILE" | sed -nE "s#^git\+ssh://git@github\.com/$GITHUB_OWNER/([A-Za-z0-9_.-]+)\.git@([0-9a-f]{40})\#egg=[A-Za-z0-9_.-]+[[:space:]]*(\#[[:space:]]*([A-Za-z0-9_./-]+))?.*#\1 \2 \4#p")
[ -n "$PINS" ] || die "no SHA-pinned lines found in $REQ_FILE"

resolve() {  # resolve <repo> <branch> -> sha or empty
  git ls-remote "git@github.com:$GITHUB_OWNER/$1.git" "refs/heads/$2" 2>/dev/null | cut -f1 | grep -E '^[0-9a-f]{40}$' || true
}

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE" "$TMP_FILE.bak"' EXIT
# Work on an LF copy; the original line endings are restored on write.
CRLF=0
[ "$(tr -cd '\r' < "$REQ_FILE" | wc -c)" -gt 0 ] && CRLF=1
tr -d '\r' < "$REQ_FILE" > "$TMP_FILE"

changed=0
failed=0
summary=""

echo "Resolving branch heads..."
while read -r repo old tracked; do
  [ -n "$repo" ] || continue
  if [ -n "$ONLY" ] && [ "${ONLY#*,$repo,}" = "$ONLY" ]; then
    continue
  fi
  tracked=${tracked:-$DEFAULT_BRANCH}
  want=${BRANCH:-$tracked}

  branch=$want
  new=$(resolve "$repo" "$branch")
  if [ -z "$new" ] && [ "$want" != "$DEFAULT_BRANCH" ]; then
    branch=$DEFAULT_BRANCH
    new=$(resolve "$repo" "$branch")
    [ -n "$new" ] && note=" (no $want branch, using $DEFAULT_BRANCH)" || note=""
  else
    note=""
  fi
  if [ -z "$new" ]; then
    printf '  %-28s FAILED: cannot resolve %s (branch missing or no SSH access)\n' "$repo" "$want"
    failed=$((failed + 1))
    continue
  fi

  label="$tracked"
  [ "$branch" != "$tracked" ] && label="$tracked -> $branch"
  if [ "$new" = "$old" ] && [ "$branch" = "$tracked" ]; then
    printf '  %-28s [%s] up to date (%s)%s\n' "$repo" "$label" "${old:0:12}" "$note"
    continue
  fi
  printf '  %-28s [%s] %s -> %s%s\n' "$repo" "$label" "${old:0:12}" "${new:0:12}" "$note"
  sed -i.bak -E "s#^(git\+ssh://git@github\.com/$GITHUB_OWNER/$repo\.git@)[0-9a-f]{40}(\#egg=[A-Za-z0-9_.-]+).*#\1$new\2  \# $branch#" "$TMP_FILE"
  changed=$((changed + 1))
  summary="$summary $repo"

  [ "$new" = "$old" ] && continue
  clone="$SILVAENGINE_SRC/$repo"
  if [ -d "$clone/.git" ] && git -C "$clone" fetch --quiet origin "$branch" 2>/dev/null \
      && git -C "$clone" cat-file -e "$old^{commit}" 2>/dev/null; then
    git -C "$clone" log --oneline --no-decorate "$old..$new" | sed 's/^/      + /'
    git -C "$clone" log --oneline --no-decorate "$new..$old" | sed 's/^/      - /'
  else
    echo "      https://github.com/$GITHUB_OWNER/$repo/compare/$old...$new"
  fi
done <<EOF
$PINS
EOF

if [ "$failed" -gt 0 ]; then
  echo "ERROR: $failed repo(s) could not be resolved; $REQ_FILE left unchanged." >&2
  exit 1
fi
if [ "$changed" -eq 0 ]; then
  echo "No pins changed."
  exit 0
fi

today=$(date +%Y-%m-%d)
sed -i.bak -E "s#(Last refreshed )[0-9]{4}-[0-9]{2}-[0-9]{2}#\1$today#" "$TMP_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: $changed pin(s) would change; $REQ_FILE not written."
  exit 0
fi

if [ "$CRLF" -eq 1 ]; then
  sed 's/$/\r/' "$TMP_FILE" > "$REQ_FILE"
else
  cat "$TMP_FILE" > "$REQ_FILE"
fi
echo "Updated $REQ_FILE ($changed pin(s):$summary)."

if [ "$BUILD" -eq 1 ]; then
  COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.bindmount.yml)
  [ "$DDB" -eq 1 ] && COMPOSE_FILES+=(-f docker-compose.ddb.yml)
  echo "Building and recreating gateway..."
  docker compose "${COMPOSE_FILES[@]}" build gateway
  docker compose "${COMPOSE_FILES[@]}" up -d gateway
  echo "Gateway recreated; check: curl http://127.0.0.1:8000/health"
fi

echo
echo "Next: git diff $REQ_FILE && git commit -am \"Bump SilvaEngine pins:$summary\""
