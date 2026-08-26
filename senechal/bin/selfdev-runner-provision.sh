#!/usr/bin/env bash
# selfdev-runner-provision.sh -- give every PRIVATE hf7y repo a self-hosted
# Actions runner on monkey, and give no public one.
#
#   selfdev-runner-provision.sh [--check|--apply]
#
# Membership is needs_runner(), read live from the GitHub API on every run:
# private AND has workflows. Both halves are the point -- see the function.
set -uo pipefail

CLI_NAME='selfdev-runner-provision.sh'
usage() {
  cat >&2 <<USAGE
usage: $CLI_NAME [--check|--apply]
  --check  (default) say what would change, write nothing; nonzero if any
           private repo lacks a runner GitHub can see
  --apply  install, register and enable one runner per private repo (root)
  --install-cadence [--apply]
           put the check on root's clock, so a runner that dies is repaired
           rather than discovered by a wedged pull request
exits:
  0  every private repo has its runner (or, under --check, could)
  1  a step refused
  2  usage
  6  BLIND -- could not look (no App credential, or the API is unreachable)
USAGE
}

MODE=--check
CADENCE=0
for a in "$@"; do
  case "$a" in
    --check|--apply) MODE="$a" ;;
    --install-cadence) CADENCE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 2 ;;
    *) echo "$CLI_NAME: unknown argument $a" >&2; usage; exit 2 ;;
  esac
done

QUIET=0
REFUSAL_LOG="$(mktemp)"; trap 'rm -f "$REFUSAL_LOG"' EXIT
HOST="$(hostname -s 2>/dev/null || echo unknown)"
API="${GITHUB_API:-https://api.github.com}"
RUNNER_ROOT="${RUNNER_ROOT:-/usr/local/lib/actions-runner}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
RUNNER_USER="${RUNNER_USER:-selfdev-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,monkey}"
RUNNER_TARBALL="${RUNNER_TARBALL:-}"
LIBEXEC="${SENECHAL_LIBEXEC:-/usr/local/libexec/senechal}"

blind() { printf '%s: BLIND: %s\n' "$CLI_NAME" "$*" >&2; exit 6; }

# --- the App credential ------------------------------------------------------
# Resolved by realisateur's bin/lib/selfdev-app-key.sh where it is installed;
# its conf is the fallback so this runs on a host without that checkout.
for lib in \
  "${SELFDEV_APP_KEY_LIB_PATH:-}" \
  /usr/local/libexec/selfdev/lib/selfdev-app-key.sh \
  "$HOME/Documents/Projects/realisateur/bin/lib/selfdev-app-key.sh"; do
  [ -n "$lib" ] && [ -r "$lib" ] && { . "$lib"; break; }
done
SELFDEV_APP_DIR="${SELFDEV_APP_DIR:-/etc/selfdev}"
if declare -F selfdev_app_load >/dev/null; then
  SELFDEV_APP_CONF="${SELFDEV_APP_CONF:-$SELFDEV_APP_DIR/gh-app.conf}"
  selfdev_app_load
  KEY_RC=$?
else
  [ -r "$SELFDEV_APP_DIR/gh-app.conf" ] && . "$SELFDEV_APP_DIR/gh-app.conf"
  SELFDEV_APP_KEY="${SELFDEV_APP_KEY:-$SELFDEV_APP_DIR/app.pem}"
  [ -n "${SELFDEV_APP_ID:-}" ] && KEY_RC=0 || KEY_RC=2
fi
OWNER="${SELFDEV_GH_OWNER:-hf7y}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

app_jwt() {
  local now hdr pay signing sig
  now="$(date +%s)"
  hdr='{"alg":"RS256","typ":"JWT"}'
  pay="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"$SELFDEV_APP_ID\"}"
  signing="$(printf '%s' "$hdr" | b64url).$(printf '%s' "$pay" | b64url)"
  sig="$(printf '%s' "$signing" | openssl dgst -sha256 -sign "$SELFDEV_APP_KEY" -binary | b64url)" || return 1
  [ -n "$sig" ] || return 1
  printf '%s.%s' "$signing" "$sig"
}

# HTTP_CODE is set by every curl_api call: the status GitHub gave, or empty
# when no answer arrived at all. "refused" and "could not look" are different
# answers and only the code separates them.
HTTP_CODE=""
curl_api() { # <method> <path> <bearer> [body]
  local out code
  HTTP_CODE=""
  out="$(curl -sS -w '\n%{http_code}' -X "$1" \
      -H "Authorization: Bearer $3" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      ${4:+-d "$4"} "$API$2")" || return 1
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  HTTP_CODE="$code"
  [ "$code" -lt 400 ] || { API_MESSAGE="$(printf '%s' "$out" | jq -r '.message // .' 2>/dev/null || printf '%s' "$out")"; return 1; }
  printf '%s' "$out"
}

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
CREDENTIAL="App"
[ -n "$TOKEN" ] && CREDENTIAL="supplied GH_TOKEN"
API_MESSAGE=""

mint_token() {
  local jwt inst
  jwt="$(app_jwt)" || blind "openssl could not sign with $SELFDEV_APP_KEY"
  inst="$(curl_api GET /app/installations "$jwt" | jq -r --arg o "$OWNER" \
    '[.[]|select(.account.login|ascii_downcase==($o|ascii_downcase))]|.[0].id // empty')" \
    || blind "GitHub did not answer /app/installations"
  [ -n "$inst" ] || blind "the App is not installed on $OWNER"
  TOKEN="$(curl_api POST "/app/installations/$inst/access_tokens" "$jwt" | jq -r '.token // empty')" \
    || blind "GitHub did not answer /app/installations/$inst/access_tokens"
  [ -n "$TOKEN" ] || blind "GitHub returned no installation token"
}

# gh_api <method> <path> [body] -- prints the response body.
# SELFDEV_RUNNER_API replaces the whole transport, so bin/tests can drive the
# predicate without a credential and without the network.
gh_api() {
  if [ -n "${SELFDEV_RUNNER_API:-}" ]; then
    "$SELFDEV_RUNNER_API" "$@"; local rc=$?
    [ "$rc" -eq 0 ] && HTTP_CODE=200 || HTTP_CODE=""
    return $rc
  fi
  [ -n "$TOKEN" ] || mint_token
  curl_api "$1" "$2" "$TOKEN" "${3:-}"
}

if [ -z "${SELFDEV_RUNNER_API:-}" ] && [ -z "$TOKEN" ]; then
  [ "$KEY_RC" -eq 0 ] || blind "no App credential in $SELFDEV_APP_DIR/gh-app.conf -- cannot tell which repos are private"
  head -c 1 -- "$SELFDEV_APP_KEY" >/dev/null 2>&1 \
    || blind "$SELFDEV_APP_KEY is not readable by uid $(id -u) -- cannot tell which repos are private"
fi

# The App sees its installation; a supplied token sees the owner's repos. Both
# are normalised to {"repositories":[...]} so the predicate reads one shape.
if [ "$CREDENTIAL" = App ] || [ -n "${SELFDEV_RUNNER_API:-}" ]; then
  REPOS_JSON="$(gh_api GET '/installation/repositories?per_page=100')" \
    || blind "could not list the installation's repositories"
else
  REPOS_JSON="$(gh_api GET "/user/repos?per_page=100&affiliation=owner" \
    | jq --arg o "$OWNER" '{repositories: [.[]|select(.owner.login==$o)]}')" \
    || blind "could not list $OWNER's repositories with the supplied token"
fi
printf '%s' "$REPOS_JSON" | jq -e '.repositories' >/dev/null 2>&1 \
  || blind "the repository listing was not JSON this script understands"

# repo_is_private <repo> -- half the membership predicate.
repo_is_private() {
  printf '%s' "$REPOS_JSON" | jq -e --arg r "$1" \
    '.repositories[]|select(.name==$r)|.private' >/dev/null 2>&1
}

# has_workflows <repo> -- the other half. A repo with no workflows cannot be
# wedged by having no runner: it is unused, not blocked. Without this the run
# demands a runner for ten private repos that have never had CI -- an archive,
# a vault, and a scratch repo among them.
has_workflows() {
  gh_api GET "/repos/$OWNER/$1/contents/.github/workflows" >/dev/null 2>&1
}

# needs_runner <repo> -- private AND has CI. Read on every run, so a repo that
# goes public, or that gains its first workflow, changes class with nothing
# edited here.
needs_runner() {
  repo_is_private "$1" && has_workflows "$1"
}

REPOS="$(printf '%s' "$REPOS_JSON" | jq -r '.repositories[].name' | sort)"
[ -n "$REPOS" ] || blind "the installation lists no repositories"

# unit_of <repo> -- the unit that actually serves this runner. svc.sh writes
# its own name into <dir>/.service; that file is the only place the truth
# lives, because the vendor names the unit after the repo AND the runner name.
# Guessing a name instead is how a second listener gets installed beside a
# working one.
unit_of() {
  local f="$RUNNER_ROOT/$1/.service"
  if [ -r "$f" ]; then sed -e 's/\.service$//' -e 's/[[:space:]]*$//' "$f"
  else printf 'actions.runner.%s-%s.%s-%s' "$OWNER" "$1" "$HOST" "$1"; fi
}

# runner_state <repo> -- what GitHub says it has: online, offline, or none.
# Presence on disk is not liveness: a revoked token leaves a happy unit and no
# runner, which is exactly the wedge this whole mechanism exists to prevent.
# The API answer is the best witness and needs Administration: read, which the
# App may not hold. When it does not answer, fall back to the local witness: a
# listener process running out of THIS runner's directory. Both are witnesses,
# neither is an assumption, and the row says which one it used. BLIND is kept
# for the case with NO witness -- not for the case where the better one is
# unavailable, which would paint ten healthy runners as unknown.
API_RUNNERS_REFUSED=""
API_RUNNERS_OK=1                       # cleared, in the PARENT, on first refusal
# Prints the state; the caller learns which witness answered from the value
# itself (online = GitHub said so, online-local = a listener on this host).
runner_state() {
  local json
  if [ "$API_RUNNERS_OK" = 1 ]; then
    json="$(gh_api GET "/repos/$OWNER/$1/actions/runners")" && {
      printf '%s' "$json" | jq -r --arg h "$HOST-$1" \
        '[.runners[]?|select(.name==$h)]|if length==0 then "none" else (.[0].status) end'
      return
    }
    printf 'refused %s: %s\n' "${HTTP_CODE:-no answer}" "${API_MESSAGE:-the runners endpoint did not answer}" >&2
  fi
  if pgrep -f "$RUNNER_ROOT/$1/bin/Runner.Listener" >/dev/null 2>&1; then printf 'online-local'; else printf 'none'; fi
}

# registration_token <repo> -- prints the token. On failure it says which door
# refused: no status at all is BLIND, a status is a refusal with GitHub's own
# message, and the App needs Administration: write to be granted one.
registration_token() {
  local json
  json="$(gh_api POST "/repos/$OWNER/$1/actions/runners/registration-token")" || {
    [ -n "$HTTP_CODE" ] \
      || blind "$API/repos/$OWNER/$1/actions/runners/registration-token gave no answer -- the API is unreachable"
    echo "  BAD     $1: $CREDENTIAL could not mint a registration token -- HTTP $HTTP_CODE: $API_MESSAGE" >&2
    [ "$HTTP_CODE" = 403 ] || [ "$HTTP_CODE" = 404 ] && \
      echo "  BAD     $1: that endpoint needs Administration: write -- grant it to the App, or re-run with GH_TOKEN=<PAT>" >&2
    return 1
  }
  printf '%s' "$json" | jq -r '.token // empty'
}

fetch_runner() { # -> prints a tarball path
  local ver url tgz
  [ -n "$RUNNER_TARBALL" ] && { printf '%s' "$RUNNER_TARBALL"; return 0; }
  ver="$(curl -sS "$API/repos/actions/runner/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//')"
  [ -n "$ver" ] || return 1
  tgz="$RUNNER_ROOT/.cache/actions-runner-linux-x64-$ver.tar.gz"
  [ -s "$tgz" ] && { printf '%s' "$tgz"; return 0; }
  url="https://github.com/actions/runner/releases/download/v$ver/actions-runner-linux-x64-$ver.tar.gz"
  install -d -m 755 "$RUNNER_ROOT/.cache" || return 1
  curl -sSL -o "$tgz" "$url" || return 1
  printf '%s' "$tgz"
}

# fault_of <repo> -- what is wrong with this runner, in the order that decides
# the CHEAPEST repair. Both modes read this, so --check and --apply can never
# disagree about what is broken.
# FAULT and LAST_WITNESS are set BY fault_of, not printed by it.
#
# TRAP: `f="$(fault_of x)"` runs the function in a subshell, so anything it
# records about HOW it learned the answer dies with that subshell -- which is
# why the run reported "GitHub could not be asked" on every row while GitHub
# was answering fine, and why the credential's refusal was never summarised.
FAULT=""
LAST_WITNESS=""
fault_of() {
  local repo="$1" dir="$RUNNER_ROOT/$repo" unit st
  unit="$(unit_of "$repo")"
  FAULT=""; LAST_WITNESS=""
  [ -d "$dir" ]                       || { FAULT=no-dir; return; }
  [ -f "$dir/.runner" ]               || { FAULT=not-registered; return; }
  [ -f "$SYSTEMD_DIR/$unit.service" ] || { FAULT=no-unit; return; }
  systemctl is-active --quiet "$unit" 2>/dev/null || { FAULT=inactive; return; }
  st="$(runner_state "$repo" 2>"$REFUSAL_LOG")"
  if [ -s "$REFUSAL_LOG" ] && [ -z "$API_RUNNERS_REFUSED" ]; then
    API_RUNNERS_REFUSED="$(sed -n '1s/^refused //p' "$REFUSAL_LOG")"; API_RUNNERS_OK=0
  fi
  case "$st" in
    online)       LAST_WITNESS=github; FAULT=ok ;;
    online-local) LAST_WITNESS=local;  FAULT=ok ;;
    unreadable)   FAULT=blind ;;
    *)            FAULT=not-serving ;;
  esac
}

# repair_one <repo> <fault> -- the smallest act that fixes THAT fault. A dead
# service is started, not re-registered: re-registering every repo because one
# unit stopped is churn on nine healthy runners, and it needs a credential the
# App may not have.
repair_one() {
  local repo="$1" fault="$2" dir="$RUNNER_ROOT/$repo" unit
  unit="$(unit_of "$repo")"
  case "$fault" in
    ok)    echo "  ok      $repo: nothing to repair"; return 0 ;;
    blind) echo "  BLIND   $repo: $unit is active and no witness could be read at all"; return 1 ;;
    inactive)
      systemctl enable --now "$unit" >/dev/null 2>&1
      if systemctl is-active --quiet "$unit"; then
        echo "  OK      $repo: $unit started (re-read, not asserted)"; return 0
      fi
      echo "  BAD     $repo: $unit would not start -- systemctl status $unit"; return 1 ;;
    no-unit)
      ( cd "$dir" && ./svc.sh install "$RUNNER_USER" >/dev/null && ./svc.sh start >/dev/null ) || {
        echo "  BAD     $repo: svc.sh could not install the service"; return 1; }
      unit="$(unit_of "$repo")"
      systemctl is-active --quiet "$unit" || { echo "  BAD     $repo: $unit is not active after svc.sh start"; return 1; }
      echo "  OK      $repo: $unit installed and started"; return 0 ;;
    *) provision_one "$repo" ;;
  esac
}

provision_one() { # <repo> -- install, register, enable
  local repo="$1" dir="$RUNNER_ROOT/$repo" unit tgz regtok
  unit="$(unit_of "$repo")"
  tgz="$(fetch_runner)" || { echo "  BAD     $repo: no runner tarball -- $API/repos/actions/runner is unreachable"; return 1; }
  install -d -m 755 -o "$RUNNER_USER" -g "$RUNNER_USER" "$dir" || return 1
  [ -x "$dir/config.sh" ] || tar -xzf "$tgz" -C "$dir" || return 1
  chown -R "$RUNNER_USER:$RUNNER_USER" "$dir" || return 1
  regtok="$(registration_token "$repo")" || return 1
  [ -n "$regtok" ] || { echo "  BAD     $repo: GitHub answered 2xx with no token in it"; return 1; }
  echo "  ..      $repo: registration token minted via $CREDENTIAL"
  sudo -u "$RUNNER_USER" "$dir/config.sh" --unattended --replace \
      --url "https://github.com/$OWNER/$repo" --token "$regtok" \
      --name "$HOST-$repo" --labels "$RUNNER_LABELS" --work _work \
    || { echo "  BAD     $repo: config.sh refused"; return 1; }
  # THE UNIT IS THE VENDOR'S. svc.sh install writes it, names it, and enables
  # it; a hand-written unit beside it is a second listener for one runner dir.
  ( cd "$dir" && ./svc.sh install "$RUNNER_USER" >/dev/null && ./svc.sh start >/dev/null ) \
    || { echo "  BAD     $repo: svc.sh could not install or start the service"; return 1; }
  unit="$(unit_of "$repo")"
  # WITNESS: re-read the three things that must be true, rather than believing
  # the exit codes above. Registered, active, and ONLINE at GitHub -- a unit
  # can run happily while GitHub sees no runner at all.
  [ -f "$dir/.runner" ] || { echo "  BAD     $repo: no .runner after config.sh -- it is not registered"; return 1; }
  systemctl is-active --quiet "$unit" || { echo "  BAD     $repo: $unit is not active"; return 1; }
  case "$(runner_state "$repo")" in
    online|online-local) ;;
    *) echo "  BAD     $repo: $unit is active but nothing is serving it"; return 1 ;;
  esac
  echo "  OK      $repo: registered as $HOST-$repo [$RUNNER_LABELS], $unit active, online at GitHub"
}

deprovision_one() { # <repo> -- a repo that went public keeps no runner
  local repo="$1" dir="$RUNNER_ROOT/$repo" unit regtok
  unit="$(unit_of "$repo")"
  systemctl disable --now "$unit" 2>/dev/null
  rm -f "$SYSTEMD_DIR/$unit.service"
  systemctl daemon-reload
  regtok="$(gh_api POST "/repos/$OWNER/$repo/actions/runners/remove-token" | jq -r '.token // empty')"
  [ -n "$regtok" ] && sudo -u "$RUNNER_USER" "$dir/config.sh" remove --token "$regtok" >/dev/null 2>&1
  rm -rf "$dir"
  [ -e "$dir" ] || [ -e "$SYSTEMD_DIR/$unit.service" ] && { echo "  BAD     $repo: runner remnants remain at $dir"; return 1; }
  echo "  OK      $repo: public -- runner removed"
}

if [ "$MODE" = --apply ] && [ "$(id -u)" -ne 0 ]; then
  echo "$CLI_NAME: --apply installs into $RUNNER_ROOT and $SYSTEMD_DIR and needs root; re-run under sudo (--check needs nothing)" >&2
  exit 1
fi

if [ "$MODE" = --apply ] && ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "/var/lib/$RUNNER_USER" --shell /usr/sbin/nologin "$RUNNER_USER" \
    || { echo "$CLI_NAME: could not create $RUNNER_USER, which the runner must run as (it refuses root)" >&2; exit 1; }
fi

# THE CLOCK. Without it this is a snapshot: a runner that dies, a token that is
# revoked, or a repo created tomorrow all present as a pull request that cannot
# merge, with nothing saying why. The line repairs rather than reports, because
# --apply is idempotent and the alternative is a silent wedge.
if [ "$CADENCE" -eq 1 ]; then
  # THE CLOCK RUNS A DEPLOYED COPY, never a checkout: a cron line pointing into
  # somebody's clone stops working the moment that clone moves, and a clone is
  # not an artifact anyone deploys.
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  installed="$LIBEXEC/$(basename "$self")"
  line="17 6 * * * $installed --check --quiet >/dev/null 2>&1 || $installed --apply # selfdev-runner:CADENCE"
  if [ "$MODE" != --apply ]; then
    echo "  would   install $self -> $installed"
    echo "  would   install into root's crontab: $line"
    exit 0
  fi
  [ "$(id -u)" -eq 0 ] || { echo "$CLI_NAME: --install-cadence --apply writes root's crontab and needs root" >&2; exit 1; }
  install -d -m 755 -o root -g root "$LIBEXEC" || exit 1
  install -m 755 -o root -g root "$self" "$installed" || exit 1
  echo "  OK      $installed"
  ( crontab -l 2>/dev/null | grep -v 'selfdev-runner:CADENCE'; printf '%s\n' "$line" ) | crontab -
  # WITNESS: read it back, as root, rather than believing `crontab -` exited 0.
  if crontab -l 2>/dev/null | grep -q 'selfdev-runner:CADENCE'; then
    echo "  OK      cadence in root's crontab (re-read, not asserted): $line"
    exit 0
  fi
  echo "  BAD     the cadence is NOT in root's crontab -- a dead runner will stay dead" >&2
  exit 1
fi

echo "== selfdev-runner-provision ($MODE) on $HOST, owner $OWNER, credential: $CREDENTIAL =="
echo "   repo list: $(printf '%s' "$REPOS" | wc -w) repo(s) this $CREDENTIAL can see"
ok_n=0; bad_n=0
for repo in $REPOS; do
  dir="$RUNNER_ROOT/$repo"; unit="$(unit_of "$repo")"; fault=""
  if needs_runner "$repo"; then
    fault_of "$repo"; fault="$FAULT"
    if [ "$MODE" = --check ]; then
      case "$fault" in
        ok)             if [ "$LAST_WITNESS" = github ]; then
                          echo "  ok      $repo: private, $unit active, GitHub sees the runner online"
                        else
                          echo "  ok      $repo: private, $unit active, a listener is serving it (GitHub could not be asked)"
                        fi
                        ok_n=$((ok_n + 1)) ;;
        no-dir)         echo "  would   $repo: private, NO DIRECTORY -- install $dir, register [$RUNNER_LABELS], enable $unit"; bad_n=$((bad_n + 1)) ;;
        not-registered) echo "  HALF    $repo: private, extracted at $dir but NOT REGISTERED (no .runner)"; bad_n=$((bad_n + 1)) ;;
        no-unit)        echo "  HALF    $repo: private, registered but NO UNIT -- svc.sh install"; bad_n=$((bad_n + 1)) ;;
        inactive)       echo "  HALF    $repo: private, $unit present but NOT ACTIVE -- systemctl enable --now $unit"; bad_n=$((bad_n + 1)) ;;
        not-serving)    echo "  HALF    $repo: $unit is active but nothing is serving it -- re-register"; bad_n=$((bad_n + 1)) ;;
        blind)          echo "  BLIND   $repo: $unit is active and no witness could be read at all"; bad_n=$((bad_n + 1)) ;;
        *)              echo "  BAD     $repo: unhandled state '$fault' -- a repo with no row is a repo nobody checked"; bad_n=$((bad_n + 1)) ;;
      esac
    elif repair_one "$repo" "$fault"; then ok_n=$((ok_n + 1)); else bad_n=$((bad_n + 1)); fi
  else
    if [ -e "$dir" ] || [ -e "$SYSTEMD_DIR/$unit.service" ]; then
      if [ "$MODE" = --check ]; then
        echo "  would   $repo: needs no runner -- REMOVE $dir and $unit (self-hosted on a public repo runs fork PRs)"
        ok_n=$((ok_n + 1))
      elif deprovision_one "$repo"; then ok_n=$((ok_n + 1)); else bad_n=$((bad_n + 1)); fi
    else
      echo "  ok      $repo: needs no runner (public, or no workflows)"
      ok_n=$((ok_n + 1))
    fi
  fi
done

echo
if [ -n "$API_RUNNERS_REFUSED" ]; then
  echo "  ..      $CREDENTIAL may not list runners ($API_RUNNERS_REFUSED), so liveness above is the"
  echo "  ..      local witness: a listener process out of each runner's own directory. Grant the"
  echo "  ..      App Administration: read, or run with GH_TOKEN=<PAT>, for GitHub's own answer."
fi
echo "== $ok_n ok, $bad_n failed =="
if [ "$MODE" = --apply ] && [ "$ok_n" -gt 0 ]; then
  echo "  DO      notify-senechal 'senechal: self-hosted Actions runners under $RUNNER_ROOT + $SYSTEMD_DIR units on $HOST, running as $RUNNER_USER. Owned by senechal.'"
fi
[ "$bad_n" -eq 0 ]
