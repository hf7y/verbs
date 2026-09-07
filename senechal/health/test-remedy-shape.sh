#!/usr/bin/env bash
# The rule-holder's own test. remedy-shape.sh runs against a fixture tree
# copied into mktemp, never against remedies/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
t() { local want=$1 desc=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc want $want)"; echo "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib" "$tmp/health" "$tmp/remedies"
cp "$HERE/../lib/common.sh" "$tmp/lib/"
cp "$HERE/remedy-shape.sh"  "$tmp/health/"
echo 0 > "$tmp/health/remedy-shape.ceiling"

remedy() { printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\nREACHES=()\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/$1"; }
remedy good.sh
echo 'x' > "$tmp/remedies/_test-good.sh"

run() { SENECHAL_SKIP_CONFIG_CHECK=1 bash "$tmp/health/remedy-shape.sh" "$@"; }
t 0 "a well-shaped remedy with a test passes" run -q

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\ncase "$1" in\n  enable) : ;;\nesac\n' > "$tmp/remedies/noverify.sh"
echo 'x' > "$tmp/remedies/_test-noverify.sh"
t 5 "a remedy with no verify) dispatch fails" run -q
rm "$tmp/remedies/noverify.sh" "$tmp/remedies/_test-noverify.sh"

printf '#!/usr/bin/env bash\nHOSTS=(mandark)\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/undeclared.sh"
echo 'x' > "$tmp/remedies/_test-undeclared.sh"
t 5 "a remedy with no PRIVILEGED line fails" run -q
rm "$tmp/remedies/undeclared.sh" "$tmp/remedies/_test-undeclared.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/nohosts.sh"
echo 'x' > "$tmp/remedies/_test-nohosts.sh"
t 5 "a remedy with no HOSTS line fails" run -q
rm "$tmp/remedies/nohosts.sh" "$tmp/remedies/_test-nohosts.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=()\nREACHES=()\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/emptyhosts.sh"
echo 'x' > "$tmp/remedies/_test-emptyhosts.sh"
t 5 "a remedy with an empty HOSTS=() fails" run -q
rm "$tmp/remedies/emptyhosts.sh" "$tmp/remedies/_test-emptyhosts.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/noreaches.sh"
echo 'x' > "$tmp/remedies/_test-noreaches.sh"
t 5 "a remedy with no REACHES line fails" run -q
rm "$tmp/remedies/noreaches.sh" "$tmp/remedies/_test-noreaches.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\nREACHES=(ssh)\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/reachessh.sh"
echo 'x' > "$tmp/remedies/_test-reachessh.sh"
t 0 "a remedy declaring REACHES=(ssh) passes" run -q
rm "$tmp/remedies/reachessh.sh" "$tmp/remedies/_test-reachessh.sh"

# #482: verify-all.sh would run this as a remedy, and auto-apply-remedies.sh
# would enable it unattended on merge.
# Each carries its own _test- file so the coverage ratchet is satisfied and
# the only rule left that can fail is the one under test.
remedy foo-test.sh; echo 'x' > "$tmp/remedies/_test-foo-test.sh"
t 5 "remedies/<x>-test.sh is caught, not only test-<x>.sh" run -q
rm "$tmp/remedies/foo-test.sh" "$tmp/remedies/_test-foo-test.sh"

remedy test-foo.sh; echo 'x' > "$tmp/remedies/_test-test-foo.sh"
t 5 "remedies/test-<x>.sh is still caught" run -q
rm "$tmp/remedies/test-foo.sh" "$tmp/remedies/_test-test-foo.sh"

echo 'x' > "$tmp/remedies/_test-vanished.sh"
t 5 "a test whose remedy is gone fails" run -q
rm "$tmp/remedies/_test-vanished.sh"

remedy untested.sh
t 5 "an untested remedy is above a ceiling of 0" run -q
: > "$tmp/remedies/_test-untested.sh"
t 5 "an EMPTY _test- file does not clear the ratchet" run -q
rm "$tmp/remedies/untested.sh" "$tmp/remedies/_test-untested.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\ninstall_file foo\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/installer.sh"
echo 'x' > "$tmp/remedies/_test-installer.sh"
t 5 "an installer with no disable) dispatch fails" run -q
printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\ninstall_file foo\ndisable_() {\n  :\n}\ncase "$1" in\n  enable) : ;;\n  verify) : ;;\n  disable) : ;;\nesac\n' > "$tmp/remedies/installer.sh"
t 5 "an installer whose disable removes nothing fails" run -q
rm "$tmp/remedies/installer.sh" "$tmp/remedies/_test-installer.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=yes\nHOSTS=(mandark)\ncase "$1" in\n  enable) sudo install -m 0755 src /usr/local/bin/x ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/rawinstall.sh"
echo 'x' > "$tmp/remedies/_test-rawinstall.sh"
t 5 "a raw \$SUDO_CMD/sudo install with no disable) dispatch fails" run -q
rm "$tmp/remedies/rawinstall.sh" "$tmp/remedies/_test-rawinstall.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\ncase "$1" in\n  enable) ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/x" ;;\n  verify) : ;;\nesac\n' > "$tmp/remedies/keygen.sh"
echo 'x' > "$tmp/remedies/_test-keygen.sh"
t 5 "ssh-keygen with no disable) dispatch fails" run -q
printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\ncase "$1" in\n  enable) ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/x" ;;\n  verify) : ;;\n  disable) rm -f "$HOME/.ssh/x" ;;\nesac\n' > "$tmp/remedies/keygen.sh"
t 5 "ssh-keygen with a disable) dispatch but no INSTALLS=(...) line still fails (#466)" run -q
rm "$tmp/remedies/keygen.sh" "$tmp/remedies/_test-keygen.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\nREACHES=()\nINSTALLS=("$HOME/.ssh/x")\ndisable_() {\n  rm -f "$HOME/.ssh/x"\n}\ncase "$1" in\n  enable) ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/x" ;;\n  verify) : ;;\n  disable) disable_ ;;\nesac\n' > "$tmp/remedies/keygen.sh"
echo 'x' > "$tmp/remedies/_test-keygen.sh"
t 0 "ssh-keygen with INSTALLS=(...) and a disable) that removes it passes" run -q
rm "$tmp/remedies/keygen.sh" "$tmp/remedies/_test-keygen.sh"

printf '#!/usr/bin/env bash\nPRIVILEGED=no\nHOSTS=(mandark)\nINSTALLS=("$HOME/.ssh/x")\ndisable_() {\n  :\n}\ncase "$1" in\n  enable) ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/x" ;;\n  verify) : ;;\n  disable) disable_ ;;\nesac\n' > "$tmp/remedies/keygen.sh"
echo 'x' > "$tmp/remedies/_test-keygen.sh"
t 5 "a declared INSTALLS path disable_() never mentions fails, even with a disable) dispatch" run -q
rm "$tmp/remedies/keygen.sh" "$tmp/remedies/_test-keygen.sh"

t 0 "the fixture is clean again" run -q

[ "$fails" = 0 ] && echo "PASS" || echo "$fails FAILED"
exit $((fails > 0))
