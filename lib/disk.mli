open Core
open Words
module Unix = Core_unix
open Units


module Fid : sig 
    (** File ids: (3 words) of sector metadata **)
    type t = flag:int * serial:int * version:int [@@deriving sexp,equal]

    (** marker for a free sector **)
    val free : t
    (** marker for a bad sector **)
    val bad : t
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
    val next        : t -> PhysAddr.t option
    (** Physical address of previous sector in this file **)
    val prev        : t -> PhysAddr.t option
    val blank       : t -> int
    (** Used number of bytes in this file **)
    val nbytes      : t -> int
    (** What page in the file is this ? **)
    val page_number : t -> PageNo.t
    (** File id **)
    val fid         : t -> Fid.t

    val is_free : t -> bool
    val is_bad  : t -> bool
    val is_data_page : t -> bool

    val set_next        : t -> PhysAddr.t option -> unit
    val set_prev        : t -> PhysAddr.t option -> unit
    val set_blank       : t -> int -> unit
    val set_nbytes      : t -> int -> unit
    val set_page_number : t -> PageNo.t -> unit
    val set_fid         : t -> Fid.t -> unit
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
    val real_disk_address : t -> PhysAddr.t
end 

(** Memory containing a disk image **)
type t

(** reads a disk image from a file **)
val of_file : string -> t

val len : t -> int

val n_sectors : t -> int

val get_sector : t -> VirtAddr.t -> Sector.t

(** Get all valid virtual addresses on this disk **)
val virtual_address_range : t -> VirtAddr.t Sequence.t

val all_sectors : t -> Sector.t Sequence.t

(** Directory entries in a DV (directory) file. Each entry begins with a single
   16-bit type+length word:
     type   = (word >> 10) & 0x3F   - 6-bit type
     length =  word & 0x3FF         - 10-bit length in WORDS

   For a file entry (type = 1):
     word 1     - reserved padding (always 0)
     word 2..4  - fid (3 words)
     word 5     - leaderVirtualDA
     word 6..   - BCPL filename string **)
module Dv_entry : sig
    val type_file : int
    val leader_vda_word_offset : int
    val name_word_offset : int
end
