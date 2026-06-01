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
dune exec bin/main.exe              # list files in SysDir (same as `ls`)
dune exec bin/main.exe ls
dune exec bin/main.exe edit NAME    # open NAME in $EDITOR (default: vim)
                                    # and write the result back to the disk
```

The Alto filename grammar matters — names usually end with a `.`
(e.g. `user.cm.`, `com.cm.`, `ALTODEFS.D.`). Editing writes back through a
shared `mmap`, so changes persist immediately on a successful editor exit.
If the editor exits non-zero, the file is left untouched.

> **Heads up:** `edit` mutates the disk image in place. Work on a copy
> (`cp tdisk4.dsk /tmp/scratch.dsk && cd /tmp && main.exe edit ...`) unless
> you know what you're doing.

## Library

The `Alto_reader.Disk` module exposes:

- `Disk.of_file` / `Disk.get_sector` / `Disk.all_sectors` — low-level
  sector access via a memory-mapped `Bigstring`.
- `Sector.header` / `Sector.label` / `Sector.data` / `Sector.real_disk_address`
  — slice a sector into its three on-disk regions.
- `Label.next` / `prev` / `nbytes` / `page_number` / `fid` (plus matching
  setters) — typed read/write of the 8-word label.
- `Bcpl_string.read` — decode a BCPL-packed length-prefixed string.
- `Listing.list_files` / `Listing.find_entry` / `Listing.entries` — walk
  SysDir.
- `File.read` / `File.write` — read or rewrite the contents of a single
  file by leader virtual disk address. `write` reuses existing pages,
  allocates from the free list when growing, and releases unused pages
  when shrinking. Byte order is unswapped/re-swapped so file contents
  come out as natural bytes (the Alto packs two bytes per word with the
  first byte in the high half).

## Capabilities and limits

- Only `SysDir` is searched; nested directories are not traversed.
- The free-page allocator looks for sectors whose label `fid` reads as
  `Fid.free` but does not update the `DiskDescriptor` bit table. Per the
  fsinfo spec the bit table is a hint, and well-behaved Alto programs
  verify free status by reading the label anyway.
- No checksums are written for the on-disk header/label/data fields.
