# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
dune build

# Run the binary (reads tdisk4.dsk in the current directory)
dune exec bin/main.exe

# Run tests
dune test

# Run a single test file
dune exec test/test_alto_reader.exe
```

## Architecture

This is an OCaml library and CLI tool for reading Xerox Alto disk images (`.dsk` files).

**Disk format** (from `fsinfo.txt`): Each sector has three fields:
- 2-word header
- 8-word label (contains file linkage: forward/backward pointers, page number, numchars, file id)
- 256-word data page

Total sector size: `2 + 8 + 256 = 266` bytes (all words are 16-bit, so `words n = n * 16 / 8`).

**`lib/disk.ml`** — the core library (`alto_reader` package):
- `Sector` module: slices a `Bigstring.t` into header/label/data sub-views using `Bigstring.sub_shared`
- `Disk` module: memory-maps a `.dsk` file and exposes `get_sector` / `all_sectors` (as a `Sequence.t`)
- `hexdump_words`: formats a `Bigstring.t` as hex words + printable chars (Alto uses big-endian 16-bit words)

**`bin/main.ml`** — prints the label of every sector in `tdisk4.dsk` as a hex dump.

**`tdisk4.dsk`** — a real Alto disk image committed to the repo, used as test data. `expected_listing` contains the correct file listing for this disk.

**Dependencies**: `core`, `core_unix`, `core_unix.bigstring_unix`, `ppx_jane` (for `[@@deriving sexp]`), `vec`.

The library uses Jane Street's `Core` throughout (`open Core` at the top of every file). `ppx_jane` provides `[@@deriving sexp]` on `Disk.t`.
