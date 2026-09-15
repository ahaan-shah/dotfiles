#!/usr/bin/env bash
# power-profile-cases.sh — prove scripts/power-profile.sh's asusd parsing
#
# asusctl answers `profile get` with "Active profile: Quiet" where
# powerprofilesctl answers with a bare "power-saver", so the asusd path has to
# parse a label out of a line and then map a name. Both halves are places to be
# quietly wrong, and quietly wrong here means a picker that shows the wrong
# profile — which nobody reports, because it looks like it works.
#
# So asusctl is stubbed on PATH and fed the shapes that matter, including the
# one that discriminates between the parse this file ships and the `awk
# '{print $NF}'` it replaced: "Super Quiet" takes the last field to "Quiet",
# which maps to a REAL profile and is wrong. Anchoring on the label yields
# "Super Quiet", which maps to nothing and hides the row — a failure that gets
# noticed.
#
# `set` is exercised against the stub too, which records its arguments instead
# of touching the daemon, so this never changes the profile of the machine it
# runs on.
set -uo pipefail

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF/../../scripts/power-profile.sh"
[ -x "$SCRIPT" ] || { echo "cannot find power-profile.sh at $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# systemctl is stubbed so the harness does not depend on asusd actually running
# on the machine running the test.
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${2:-}" = "--quiet" ] || true
case " $* " in *" asusd "*) exit 0 ;; esac
exit 1
EOF
chmod +x "$TMP/bin/systemctl"

stub_get() {   printf '%s' "$1" >"$TMP/get-output"; }
cat >"$TMP/bin/asusctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
    "profile get") cat "$TMPDIR_FOR_STUB/get-output" ;;
    "profile set") printf '%s' "${3:-}" >"$TMPDIR_FOR_STUB/set-arg" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/asusctl"

PASS=0; FAIL=0
run_get() { PATH="$TMP/bin:$PATH" TMPDIR_FOR_STUB="$TMP" HOME="$TMP" "$SCRIPT" get; }

expect_get() {
    local name="$1" output="$2" want="$3"
    stub_get "$output"
    local got; got="$(run_get)"
    if [ "$got" = "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"; PASS=$((PASS+1))
    else
        printf '  \033[31m✗\033[0m %s — got "%s", wanted "%s"\n' "$name" "$got" "$want"
        FAIL=$((FAIL+1))
    fi
}

echo
echo "power-profile.sh — asusd parsing"
echo

# ── the three real answers ──────────────────────────────────────────────
expect_get "Quiet -> power-saver"        $'Active profile: Quiet\n\n'       "power-saver"
expect_get "Balanced -> balanced"        $'Active profile: Balanced\n\n'    "balanced"
expect_get "Performance -> performance"  $'Active profile: Performance\n\n' "performance"

# ── the case the old parse got WRONG ────────────────────────────────────
# awk '{print $NF}' yields "Quiet" here and maps it to a real profile. The
# anchored parse yields "Super Quiet", maps it to nothing, and the row hides.
expect_get "a multi-word name is not mistaken for its last word" \
    $'Active profile: Super Quiet\n\n' ""

# ── shapes that must still work ─────────────────────────────────────────
expect_get "leading whitespace"      $'  Active profile: Quiet\n'   "power-saver"
expect_get "CRLF line ending"        $'Active profile: Quiet\r\n'   "power-saver"
expect_get "lowercase name"          $'Active profile: quiet\n'     "power-saver"
expect_get "trailing spaces"         $'Active profile: Quiet   \n'  "power-saver"
expect_get "a preamble line first"   $'Some notice\nActive profile: Balanced\n' "balanced"

# ── shapes that must yield nothing rather than a guess ──────────────────
expect_get "empty output"            ""                              ""
expect_get "an error message"        $'Error: no daemon\n'           ""
expect_get "the label itself changed" $'Current profile = Quiet\n'   ""

# ── set maps the other way, and never touches -a/-b ─────────────────────
expect_set() {
    local want_arg="$1" give="$2"
    rm -f "$TMP/set-arg"
    PATH="$TMP/bin:$PATH" TMPDIR_FOR_STUB="$TMP" HOME="$TMP" "$SCRIPT" set "$give" >/dev/null 2>&1
    local got; got="$(cat "$TMP/set-arg" 2>/dev/null || true)"
    if [ "$got" = "$want_arg" ]; then
        printf '  \033[32m✓\033[0m set %s -> asusctl profile set %s\n' "$give" "$want_arg"; PASS=$((PASS+1))
    else
        printf '  \033[31m✗\033[0m set %s — asusctl got "%s", wanted "%s"\n' "$give" "$got" "$want_arg"
        FAIL=$((FAIL+1))
    fi
}
expect_set Quiet       power-saver
expect_set Balanced    balanced
expect_set Performance performance

# An unknown profile must be refused rather than passed through to the daemon.
rm -f "$TMP/set-arg"
if PATH="$TMP/bin:$PATH" TMPDIR_FOR_STUB="$TMP" HOME="$TMP" "$SCRIPT" set turbo >/dev/null 2>&1; then
    printf '  \033[31m✗\033[0m an unknown profile was accepted\n'; FAIL=$((FAIL+1))
else
    [ -f "$TMP/set-arg" ] \
        && { printf '  \033[31m✗\033[0m an unknown profile still reached asusctl\n'; FAIL=$((FAIL+1)); } \
        || { printf '  \033[32m✓\033[0m an unknown profile is refused and never reaches asusctl\n'; PASS=$((PASS+1)); }
fi

echo
if [ "$FAIL" = 0 ]; then printf '  \033[32m%d passed\033[0m\n\n' "$PASS"
else printf '  \033[31m%d failed\033[0m, %d passed\n\n' "$FAIL" "$PASS"; fi
exit $(( FAIL > 0 ))
