# Alto `.dsk` File Format and Directory Listing

This document describes the on-disk layout of `tdisk4.dsk` (a Xerox Alto
Diablo-Model-31 disk image) and the procedure for producing a file listing
from it. It supersedes the rough sketch in `CLAUDE.md` and `fsinfo.txt` with
concrete byte offsets verified against the actual file.

## 1. Overall file shape

`tdisk4.dsk` is 2 601 648 bytes. The Diablo-Model-31 has

    203 cylinders × 2 heads × 12 sectors/track = 4 872 sectors

so each sector occupies exactly `2 601 648 / 4 872 = 534` bytes
(`= 267` 16-bit words). The file is **indexed by virtual disk address**:
sector at file offset `N * 534` is the data for virtual disk address `N`.

### 1.1 Word storage

Each 16-bit Alto word is stored **little-endian** in the file
(low byte first, high byte second). All examples below give the
*little-endian-decoded* word value — i.e. the value the Alto CPU sees.

## 2. Per-sector layout (267 words, indexed from 0)

| Word index   | Field                 | Notes                                                    |
| :----------- | :-------------------- | :------------------------------------------------------- |
| `0`          | leading pad           | Always `0x0000`. (Hardware sync / reserved.)             |
| `1`          | header word 1         | Always `0x0000` in this image. (Header checksum slot.)   |
| `2`          | header word 2         | **Real disk address of this sector** (see §3).           |
| `3..10`      | label (8 words)       | See §4.                                                  |
| `11..266`    | data page (256 words) | The actual contents — file data, leader page, etc.       |

So the "2-word header / 8-word label / 256-word data page" structure that
`fsinfo.txt` describes is the data at words `1..266`; an extra pad word at
position 0 brings the total to 267.

## 3. Real disk addresses

The label fields (§4) store `next`/`prev` pointers as 16-bit *real* disk
addresses. The encoding (verified by inspecting sectors 0, 1, 11, 12, 24,
4871) is:

| Bit range (LSB-numbered) | Field                       | Width   |
| :----------------------- | :-------------------------- | :------ |
| 12 .. 15                 | sector within track (0..11) | 4 bits  |
| 11                       | reserved                    | 1 bit   |
| 3 .. 10                  | cylinder (0..202)           | 8 bits  |
| 2                        | head (0 or 1)               | 1 bit   |
| 0 .. 1                   | reserved (restore, drive)   | 2 bits  |

The mapping between virtual disk address and (cyl, head, sec) is

    cylinder = vaddr / 24
    head     = (vaddr % 24) / 12
    sector   = vaddr % 12

So:

| Virtual addr | (cyl, head, sec) | Real DA  |
| -----------: | :--------------- | :------- |
| 0            | (0, 0, 0)        | `0x0000` |
| 1            | (0, 0, 1)        | `0x1000` |
| 11           | (0, 0, 11)       | `0xB000` |
| 12           | (0, 1, 0)        | `0x0004` |
| 24           | (1, 0, 0)        | `0x0008` |
| 4871         | (202, 1, 11)     | `0xB654` |

Note: for the listing algorithm in §7 we never need to convert real ↔ virtual
addresses, because we scan all sectors and group them by file id.

## 4. Label (words 3..10 of each sector)

| Label offset | Name           | Meaning                                                                                   |
| -----------: | :------------- | :---------------------------------------------------------------------------------------- |
| 0            | `next`         | Real DA of next page in this file, or `0` if last page.                                   |
| 1            | `prev`         | Real DA of previous page, or `0` if this is page 0 (leader).                              |
| 2            | `blank`        | Always `0x0000` for a valid label.                                                        |
| 3            | `nbytes`       | Number of data bytes used in this page (0..512). Always 512 except on the last page.     |
| 4            | `pageNumber`   | 0 = leader page, 1..N = data pages.                                                       |
| 5            | `fid[0]`       | Flag word: `dirFlag` etc. Free pages have `0xFFFF`; permanently bad pages `0xFFFE`.       |
| 6            | `fid[1]`       | File serial number.                                                                       |
| 7            | `fid[2]`       | File version.                                                                             |

The triple `(fid[0], fid[1], fid[2])` is the file id; every page belonging
to the same file shares the same triple.

## 5. BCPL string packing

Filenames are stored as BCPL byte strings packed two bytes per word with
byte 0 in the **high** byte:

    byte 0  = (word[0] >> 8) & 0xFF      -- length (0..maxLengthFn)
    byte 1  =  word[0]       & 0xFF      -- first character
    byte 2  = (word[1] >> 8) & 0xFF      -- second character
    byte 3  =  word[1]       & 0xFF      -- ...

So to read an `L`-char BCPL string starting at word `W`:

    length = (words[W] >> 8) & 0xFF
    for k in 1..length:
        wi = W + k/2
        byte = if k is even then (words[wi] >> 8) & 0xFF
               else            words[wi]       & 0xFF

If `length` is odd, the trailing byte at the end of the last word is a
"garbage byte" which must be `0`.

## 6. Leader page (page 0 of any file)

Sector with `pageNumber == 0` is the file's leader. The standard fields
relevant for a listing are timestamps in words `0..5` (created, written,
read — 2 words each, low-half of an Alto 32-bit time) and the **filename
as a BCPL string starting at data word 6**.

`SysDir` itself lives at **virtual disk address 1**, so its leader page is
the data of sector 1. Reading the string at data word 6 of sector 1 yields
the BCPL string `"SysDir."` (length 7) — a useful sanity check.

## 7. Directory file (`DV`) entry format

A directory file is a stream of variable-length entries. Page boundaries
are *not* respected — concatenate all data pages (respecting `nbytes` on
the final page) into a flat word stream first.

Each entry begins with a single word:

    typeLength = (type << 10) | length          (LSB-numbered)
        type   = (word >> 10) & 0x3F            -- 6-bit type
        length =  word        & 0x3FF           -- 10-bit length in WORDS

`fsinfo.txt` names the relevant types `dvTypeFree = 0` and
`dvTypeFile = 1`. A type-1 entry's body is laid out as

| Entry word offset | Contents                                                        |
| ----------------: | :-------------------------------------------------------------- |
| 0                 | `typeLength`                                                    |
| 1                 | reserved / padding (always `0`)                                 |
| 2                 | `fid[0]` (flag word)                                            |
| 3                 | `fid[1]` (serial number)                                        |
| 4                 | `fid[2]` (version)                                              |
| 5                 | `leaderVirtualDA` (virtual disk address of the leader page)     |
| 6..end            | BCPL filename string                                            |

The entry's `length` includes the header word, so the next entry begins
at `i + length` words into the stream. Type-0 entries are skipped (they
represent free space inside the directory file — the tail of `SysDir` in
`tdisk4.dsk` is full of them).

## 8. Producing the file listing

1. Open `tdisk4.dsk` and treat it as 4 872 sectors of 534 bytes each,
   reading each 16-bit word little-endian.
2. Locate `SysDir`: read sector 1; its label gives its `fid` triple.
3. Scan all 4 872 sectors; for every sector whose label `fid` matches
   `SysDir`'s, record `(pageNumber, nbytes, data[256 words])`.
4. Concatenate the data of pages `1..max_page` in order. On the **last**
   page only, truncate to `nbytes` bytes.
5. Re-interpret the resulting byte stream as 16-bit little-endian words
   and walk it as a sequence of `DV` entries (§7), collecting the BCPL
   filename of every `dvTypeFile` entry.

Running this against `tdisk4.dsk` yields **124 filenames**, all of which
appear in `expected_listing`.

### 8.1 The 25 names in `expected_listing` not produced by this algorithm

`expected_listing` has 149 names; the 25 not produced are
`?.` plus 24 commands ending in `.~.`
(`Bootfrom.~.`, `BootKeys.~.`, `Chat.~.`, `Copy.~.`, `Delete.~.`,
`Dump.~.`, `EtherBoot.~.`, `FileStat.~.`, `Ftp.~.`, `Install.~.`,
`Load.~.`, `LogIn.~.`, `MesaBanks.~.`, `NetExec.~.`, `Partition.~.`,
`Quit.~.`, `Release.~.`, `Rename.~.`, `Resume.~.`, `Scavenger.~.`,
`SetTime.~.`, `StandardRam.~.`, `Type.~.`, `WriteDirectory.~.`).

These are not present in `SysDir` as type-1 entries; they are the
Executive's built-in commands, conventionally listed alongside the
on-disk directory when the user types `?`. Reproducing the exact
`expected_listing` therefore requires layering this fixed set of
Executive command names on top of the on-disk `SysDir` contents.
