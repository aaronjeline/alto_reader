# alto_reader

An OCaml library and CLI for reading and editing files inside a Xerox Alto
disk image (`.dsk`).

The on-disk format — sector layout, label fields, BCPL byte packing, and the
directory entry structure — is documented in [FORMAT.md](FORMAT.md).

## Build

```sh
dune build
dune test          # inline test suite (depends on tdisk4.dsk)
```

## CLI

The executable operates on `./tdisk4.dsk` in the current working directory.

```sh
alto_reader                       # list files in SysDir (same as `ls`)
alto_reader ls
alto_reader edit NAME             # open NAME in $EDITOR (default: vim)
                                  # and write the result back to the disk
```

The Alto filename grammar matters — names usually end with a `.`
(e.g. `user.cm.`, `com.cm.`, `ALTODEFS.D.`). Editing writes back through a
shared `mmap`, so changes persist immediately on a successful editor exit.
If the editor exits non-zero, the file is left untouched.

> **Heads up:** `edit` mutates the disk image in place. Work on a copy
> (`cp tdisk4.dsk /tmp/scratch.dsk`) unless you know what you're doing.

## Library layout

All modules live in the `Alto_reader` library (`lib/`):

| Module | Purpose |
|---|---|
| `Words` | Word-level I/O (`read_word`/`write_word`) and byte-offset constants |
| `Disk` | Memory-maps a `.dsk` file; `Sector`, `Label`, and `Fid` sub-modules |
| `Hex` | `hexdump_words` — formats a `Bigstring` as hex words + printable chars |
| `Bcpl_string` | Decodes a BCPL length-prefixed, byte-swapped string |
| `Listing` | Walks SysDir by following the next-pointer chain |
| `File` | Reads and rewrites the contents of a named file |

### Key APIs

**`Disk`**
- `Disk.of_file` / `get_sector` / `all_sectors` — low-level sector access via a shared `mmap`.
- `Sector.header` / `label` / `data` / `real_disk_address` — slice a sector into its three regions.
- `Label.next` / `prev` / `nbytes` / `page_number` / `fid` and matching setters — typed read/write of the 8-word label.

**`Listing`**
- `Listing.list_files` — returns the names of all files in SysDir.
- `Listing.find_file` — looks up a `File.t` by name.
- `Listing.files` — returns all `File.t` records.

**`File`**
- `File.read disk file` — reads and unswaps the bytes of a file into a `Bytes.t`.
- `File.write disk file data` — writes data back, reusing existing pages,
  allocating from the free list when growing, and releasing pages when shrinking.
  Applies the same byte-pair swap as `read` so round-trips are transparent.

## Capabilities and limits

- Only `SysDir` is searched; nested directories are not traversed.
- The free-page allocator looks for sectors whose label `fid` reads as
  `Fid.free` but does not update the `DiskDescriptor` bit table. Per the
  fsinfo spec the bit table is a hint, and well-behaved Alto programs verify
  free status by reading the label anyway.
- No checksums are written for the on-disk header/label/data fields.
