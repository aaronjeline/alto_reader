# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
dune build

# Run the binary (operates on ./tdisk4.dsk in the cwd)
dune exec bin/main.exe              # default: lists files in SysDir
dune exec bin/main.exe -- ls
dune exec bin/main.exe -- edit NAME # opens NAME in $EDITOR (default: vim)
                                    # and writes the result back to the disk

# Run the full inline-test suite (depends on tdisk4.dsk)
dune test

# Run a single inline test by name (substring match)
dune runtest --force --no-buffer test/ -- -only-test "find_file locates user.cm"
```

Tests are written as `let%test_unit` inline tests in `test/test_alto_reader.ml` (not standalone executables). Each test copies `tdisk4.dsk` to a temp file via `with_disk_copy` so the committed image is never mutated.

## On-disk layout

The authoritative format reference is [FORMAT.md](FORMAT.md); `fsinfo.txt` is the original Xerox documentation. Quick summary:

- A sector is **267 16-bit words = 534 bytes**, laid out as:
  - `word[0]` — leading pad (always 0)
  - `word[1..2]` — 2-word header (`word[2]` is the sector's "real disk address")
  - `word[3..10]` — 8-word label (forward/back links, page number, byte count, file id)
  - `word[11..266]` — 256-word data page
- Words are stored **little-endian on disk**, but the Alto OS swaps bytes within each pair before writing file contents — so reading file *data* requires unswapping. `File.read` / `File.write` apply that swap so callers see plain bytes.
- Sectors of a file form a doubly-linked list via label `next`/`prev` (virtual disk addresses). Page 0 of every file is the "leader" page; data pages have `page_number > 0`.
- A free sector is identified by its label `fid` matching `Fid.free` (`0xFFFF, 0xFFFF, 0xFFFF`). The free-page allocator scans labels rather than consulting the `DiskDescriptor` bit table.

## Library structure (`lib/`)

All modules live in the `Alto_reader` library:

- **`Words`** — byte/word constants (`bytes_per_word`, `sector_bytes`, `label_byte_offset`, etc.) and `read_word` / `write_word` (little-endian 16-bit).
- **`Disk`** — memory-maps a `.dsk` file with `~shared:true`, so writes through the returned `Bigstring.t` go straight to the file. Contains nested modules:
  - `Disk.Sector` — slices a sector into header/label/data sub-views using `Bigstring.sub_shared` (zero-copy aliases into the mmap).
  - `Disk.Label` — typed getters/setters over the 8-word label (`next`, `prev`, `nbytes`, `page_number`, `fid`, plus `set_*`).
  - `Disk.Fid` — the 3-word file id, with sentinel values `Fid.free` and `Fid.bad`.
  - `Disk.Dv_entry` — constants for parsing directory-entry words (`type_file = 1`, `leader_vda_word_offset`, `name_word_offset`).
- **`Hex`** — `hexdump_words` formats a `Bigstring` as hex words plus printable chars; used for debugging.
- **`Bcpl_string`** — decodes BCPL length-prefixed, byte-swapped strings (filenames live in this form).
- **`Listing`** — walks `SysDir`. Exposes `list_files`, `find_file ~name`, and `files`. Only `SysDir` is searched; nested directories are not traversed.
- **`File`** — `File.read disk file` returns the unswapped bytes of a named file; `File.write disk file data` writes back, reusing existing pages, pulling from the free list when growing, and releasing pages when shrinking. The byte-pair swap on write is the exact inverse of the one on read, so round-trips are transparent.

## Key invariants when modifying file I/O

- `Disk.of_file` mmaps **shared, read/write**. Any mutation to a `Bigstring` returned by `Sector.label` / `Sector.data` is an immediate write to the on-disk image. Tests must run on a copy.
- `File.write` is the only path that allocates/frees pages. It does not update the `DiskDescriptor` bit table (per the fsinfo spec, it's a hint and well-behaved Alto programs verify free-ness via the label anyway).
- No checksums are written for header/label/data.
- The Alto filename grammar matters — names usually end with a literal `.` (e.g. `user.cm.`, `com.cm.`, `ALTODEFS.D.`).

## Conventions

- Every file starts with `open Core`. The library uses Jane Street's `Core` throughout.
- `ppx_jane` is enabled for `[@@deriving sexp]` and for `let%test_unit` inline tests.
- Dependencies (from `lib/dune`): `core`, `core_unix`, `core_unix.bigstring_unix`, `vec`. The binary additionally uses `core_unix.filename_unix`.
- Test data: `tdisk4.dsk` is a real Alto disk image committed to the repo; `expected_listing` is the correct file listing for it.
