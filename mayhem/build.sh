#!/usr/bin/env bash
# mayhem/build.sh — util-linux: sanitized fuzz build + standalone reproducers + normal-flags test build.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS SRC

TARGETS="test_blkid_fuzz test_fdisk_fuzz test_fdisk_script_fuzz test_last_fuzz test_mount_fuzz test_smartcols_fuzz"

cd "$SRC"
[ -x ./configure ] || ./autogen.sh >/dev/null

# 1) Sanitized fuzz build (libraries instrumented; engine linked only at the end).
FUZZ="$SRC/mayhem/build/fuzz"
rm -rf "$FUZZ"; mkdir -p "$FUZZ"; cd "$FUZZ"
"$SRC/configure" CC="$CC" \
    CFLAGS="-O1 -fno-omit-frame-pointer $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION" \
    LDFLAGS="$SANITIZER_FLAGS" \
    --disable-all-programs --enable-libuuid --enable-libfdisk --enable-last \
    --enable-fuzzing-engine --enable-libmount --enable-libblkid --enable-libsmartcols \
    --disable-nls >/dev/null

# LSan is disabled at build time (see rules/c.md).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c++ -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ/standalone_main.o"

# GNU make resolves targets through VPATH=$SRC, so a finished binary left at $SRC/<t> would be
# mistaken for the build-dir target: clear them first and only publish them after both links.
for t in $TARGETS; do rm -f "$SRC/$t" "$SRC/$t-standalone"; done
mkdir -p "$FUZZ/stash"

# libFuzzer binaries
for t in $TARGETS; do rm -f "$FUZZ/$t"; done
make -j"$MAYHEM_JOBS" check-programs LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $FUZZ/lsan_off.o" >/dev/null
for t in $TARGETS; do cp "$FUZZ/$t" "$FUZZ/stash/$t"; done

# Standalone (run-once) reproducers: relink the same objects against the standalone driver.
for t in $TARGETS; do rm -f "$FUZZ/$t"; done
make -j"$MAYHEM_JOBS" check-programs LIB_FUZZING_ENGINE="$FUZZ/standalone_main.o $FUZZ/lsan_off.o" >/dev/null
for t in $TARGETS; do cp "$FUZZ/$t" "$FUZZ/stash/$t-standalone"; done
for t in $TARGETS; do cp "$FUZZ/stash/$t" "$FUZZ/stash/$t-standalone" "$SRC/"; done

# 2) Test suite build: project's normal flags, separate tree.
TB="$SRC/mayhem/build/test"
rm -rf "$TB"; mkdir -p "$TB"; cd "$TB"
env -u CFLAGS -u LDFLAGS "$SRC/configure" CC="$CC" CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
    --disable-nls --disable-asciidoc --disable-poman --without-python --without-systemd --without-udev >/dev/null
make -j"$MAYHEM_JOBS" >/dev/null
make -j"$MAYHEM_JOBS" check-programs >/dev/null
