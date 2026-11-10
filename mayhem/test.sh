#!/usr/bin/env bash
# mayhem/test.sh — behavioral oracle for util-linux: known-answer probes against the built
# binaries, then the project's own golden-output suite (tests/run.sh). Built by mayhem/build.sh.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/mayhem/build/test"
if [ ! -x "$B/hexdump" ] || [ ! -x "$B/blkid" ] || [ ! -x "$B/sfdisk" ] || [ ! -f "$B/test_ttyutils" ]; then
  echo "test binaries missing under $B — mayhem/build.sh must build them" >&2
  emit_ctrf "util-linux" 0 1 0
  exit 1
fi

passed=0; failed=0
kat() { # kat <name> <expected> <actual>
  if [ "$2" == "$3" ]; then passed=$((passed+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1"; echo "  expected: $(printf '%q' "$2")"; echo "  actual:   $(printf '%q' "$3")"; fi
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export TZ=UTC LC_ALL=C

kat hexdump "$(printf '00000000  41 42 43                                          |ABC|\n00000003')" \
    "$(printf 'ABC' | "$B/hexdump" -C)"
kat rev "cba" "$(printf 'abc\n' | "$B/rev")"
kat column "$(printf 'a    bb\nccc  d')" "$(printf 'a bb\nccc d\n' | "$B/column" -t)"
kat uuidparse "DCE time-based" "$("$B/uuidparse" -n -o VARIANT,TYPE 6ba7b810-9dad-11d1-80b4-00c04fd430c8 | tr -s ' ')"
kat cal "$(printf '    February 2024\nMo Tu We Th Fr Sa Su\n          1  2  3  4\n 5  6  7  8  9 10 11\n12 13 14 15 16 17 18\n19 20 21 22 23 24 25\n26 27 28 29')" \
    "$("$B/cal" -1 -m 2 2024 | sed 's/ *$//')"
kat colrm "ad" "$(printf 'abcd\n' | "$B/colrm" 2 3)"

# libfdisk/sfdisk write a DOS table into a plain file; libblkid and fdisk read it back.
truncate -s 10M "$W/disk.img"
printf 'label: dos\nlabel-id: 0x12345678\nstart=2048, size=4096, type=83\nstart=8192, size=2048, type=82\n' \
  | "$B/sfdisk" -q "$W/disk.img" >/dev/null 2>&1
kat blkid-pttype "dos" "$("$B/blkid" -p -o value -s PTTYPE "$W/disk.img")"
kat blkid-ptuuid "12345678" "$("$B/blkid" -p -o value -s PTUUID "$W/disk.img")"
kat sfdisk-dump "$(printf 'type=83\ntype=82')" "$("$B/sfdisk" -d "$W/disk.img" | grep -o 'type=[0-9a-f]*')"
kat sfdisk-size "$(printf '4096\n2048')" "$("$B/sfdisk" -d "$W/disk.img" | sed -n 's/.*size= *\([0-9]*\),.*/\1/p')"
kat fdisk-list "$(printf 'Linux\nLinux swap / Solaris')" "$("$B/fdisk" -l "$W/disk.img" 2>/dev/null | sed -n '/^\/\//d; s/^[^ ]*img[0-9] .* [0-9.]*[KMG] [0-9a-f]* //p')"

echo "== tests/run.sh =="
rm -rf "$B/tests/output" "$B/tests/diff"
out="$("$SRC/tests/run.sh" --nonroot --parallel="$MAYHEM_JOBS" --srcdir="$SRC" --builddir="$B" \
  --exclude=libmount/config \
  blkid libmount libsmartcols libfdisk fdisk sfdisk sha1 md5 column hexdump rev col colrm cal uuid uuidparse bitops utmp misc cramfs more ul look line namei getopt isosize mcookie 2>&1)"
echo "$out" | tail -n 25
sp=$(grep -cE '\.\.\. +OK$|\.\.\. +PASSED$' <<<"$out" || true)
sf=$(grep -cE '\.\.\. +FAILED' <<<"$out" || true)
ss=$(grep -cE '\.\.\. +SKIPPED' <<<"$out" || true)
if ! grep -q 'All [0-9]* tests PASSED' <<<"$out" || [ "$sp" -lt 100 ]; then failed=$((failed+1)); echo "FAIL tests/run.sh (ok=$sp failed=$sf skipped=$ss)"; fi
passed=$((passed+sp)); failed=$((failed+sf))
emit_ctrf "util-linux" "$passed" "$failed" "$ss"
