#!/usr/bin/env bash
# mayhem/build.sh — util-linux: sanitized col (stdin target) + normal-flags test build.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS SRC

cd "$SRC"
[ -x ./configure ] || ./autogen.sh >/dev/null

# 1) Sanitized col (reads stdin; Mayhem feeds the input there): libraries and col.c instrumented.
FUZZ="$SRC/mayhem/build/fuzz"
rm -rf "$FUZZ"; mkdir -p "$FUZZ"; cd "$FUZZ"
"$SRC/configure" CC="$CC" \
    CFLAGS="-O1 -fno-omit-frame-pointer $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION" \
    LDFLAGS="$SANITIZER_FLAGS" \
    --disable-all-programs --enable-col --disable-nls >/dev/null

# LSan is disabled at build time (see rules/c.md).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c++ -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ/lsan_off.o"

rm -f "$SRC/col_stdin"
make -j"$MAYHEM_JOBS" col LDFLAGS="$SANITIZER_FLAGS $FUZZ/lsan_off.o" >/dev/null
cp "$FUZZ/col" "$SRC/col_stdin"

# 2) Test suite build: project's normal flags, separate tree.
TB="$SRC/mayhem/build/test"
rm -rf "$TB"; mkdir -p "$TB"; cd "$TB"
env -u CFLAGS -u LDFLAGS "$SRC/configure" CC="$CC" CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
    --disable-nls --disable-asciidoc --disable-poman --without-python --without-systemd --without-udev >/dev/null
make -j"$MAYHEM_JOBS" >/dev/null
make -j"$MAYHEM_JOBS" check-programs >/dev/null
