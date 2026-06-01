open Core
open Words
module Unix = Core_unix

(**
   A Xerox Alto Diablo Disk file system library

   See FORMAT.md for a description of the on-disk layout.

   Each sector is 267 16-bit words = 534 bytes:
     word[0]      - leading pad (always 0)
     word[1..2]   - 2-word header (word[2] = real disk address of this sector)
     word[3..10]  - 8-word label
     word[11..266] - 256-word data page

   Words are stored little-endian in the file. 
**)


(** 
   A file ID is composed of three words:
       A flag (which can signal a free or bad sector)
       A serial number
       A version

    The file id is consistent across all sectors belonging to the same file.

**)
module Fid = struct
    (** File ids: (3 words) of sector metadata **)
    type t = flag:int * serial:int * version:int [@@deriving sexp,equal]

    (** marker for a free sector **)
    let free = (~flag:0xFFFF, ~serial:0xFFFF, ~version:0xFFFF)
    (** marker for a bad sector **)
    let bad  = (~flag:0xFFFE, ~serial:0xFFFE, ~version:0xFFFE)
end

module Label : sig
    (** Labels are the main source of metadata in a sector 
        **)

    (** A Diablo sector label *)
    type t

    (** Load a Label. 
        Must be 8 words **)
    val of_bigstring : Bigstring.t -> t

    (** Physical address of next sector in this file **)
    val next        : t -> int
    (** Physical address of previous sector in this file **)
    val prev        : t -> int
    val blank       : t -> int
    (** Used number of bytes in this file **)
    val nbytes      : t -> int
    (** What page in the file is this ? **)
    val page_number : t -> int
    (** File id **)
    val fid         : t -> Fid.t

    val is_free : t -> bool
    val is_bad  : t -> bool
    val is_data_page : t -> bool

    val set_next        : t -> int -> unit
    val set_prev        : t -> int -> unit
    val set_blank       : t -> int -> unit
    val set_nbytes      : t -> int -> unit
    val set_page_number : t -> int -> unit
    val set_fid         : t -> Fid.t -> unit
end = struct
    type t = Bigstring.t

    let of_bigstring buf =
        assert (Bigstring.length buf = label_words * bytes_per_word);
        buf

    let word_at     t i   = read_word  t ~pos:(i * bytes_per_word)
    let set_word_at t i v = write_word t ~pos:(i * bytes_per_word) v

    let next        t = word_at t 0
    let prev        t = word_at t 1
    let blank       t = word_at t 2
    let nbytes      t = word_at t 3
    let page_number t = word_at t 4
    let fid         t = (~flag:(word_at t 5), 
                        ~serial:(word_at t 6), 
                        ~version:(word_at t 7))

    let is_free t = Fid.equal (fid t) Fid.free
    let is_bad  t = Fid.equal (fid t) Fid.bad
    let is_data_page t = page_number t <> 0

    let set_next        t v = set_word_at t 0 v
    let set_prev        t v = set_word_at t 1 v
    let set_blank       t v = set_word_at t 2 v
    let set_nbytes      t v = set_word_at t 3 v
    let set_page_number t v = set_word_at t 4 v
    let set_fid t (~flag, ~serial, ~version) =
        set_word_at t 5 flag;
        set_word_at t 6 serial;
        set_word_at t 7 version
end

module Sector : sig
    (** A disk file system is organized in sectors 
        sectors are stored in a series of doubly-linked lists 
        that form files 
     **)


    (** a pointer to a sector **)
    type t

    val sector_size : int

    val create : Bigstring.t -> pos:int -> t

    val header            : t -> Bigstring.t
    val label             : t -> Label.t
    val data              : t -> Bigstring.t
    val real_disk_address : t -> int
end = struct
    type t = Bigstring.t

    let sector_size = sector_bytes

    let create buf ~pos =
        Bigstring.sub_shared ~pos ~len:sector_bytes buf

    let header buf =
        Bigstring.sub_shared ~pos:(pad_words * bytes_per_word)
                             ~len:(header_words * bytes_per_word) buf

    let label buf =
        Label.of_bigstring
          (Bigstring.sub_shared ~pos:label_byte_offset
                                ~len:(label_words * bytes_per_word) buf)

    let data buf =
        Bigstring.sub_shared ~pos:data_byte_offset
                             ~len:(data_words * bytes_per_word) buf

    let real_disk_address buf = read_word buf ~pos:real_da_byte_offset
end


(** Memory containing a disk image **)
type t = {
    buf : Bigstring.t;
    len : int
}
[@@deriving sexp]

(** reads a disk image from a file **)
let of_file filename =
    let f = Unix.openfile filename ~mode:[Unix.O_RDWR] in
    let stat = Unix.fstat f in
    let len = Int64.to_int_exn stat.st_size in
    let buf = Bigstring_unix.map_file ~shared:true f len in
    { len; buf }

let n_sectors disk = disk.len / Sector.sector_size

let get_sector disk sector_num =
    Sector.create disk.buf ~pos:(sector_num * Sector.sector_size)

let all_sectors disk =
    Sequence.range 0 (n_sectors disk)
    |> Sequence.map ~f:(get_sector disk)


(** Directory entries in a DV (directory) file. Each entry begins with a single
   16-bit type+length word:
     type   = (word >> 10) & 0x3F   - 6-bit type
     length =  word & 0x3FF         - 10-bit length in WORDS

   For a file entry (type = 1):
     word 1     - reserved padding (always 0)
     word 2..4  - fid (3 words)
     word 5     - leaderVirtualDA
     word 6..   - BCPL filename string **)
module Dv_entry = struct
    let type_file = 1
    let leader_vda_word_offset = 5
    let name_word_offset = 6
end


