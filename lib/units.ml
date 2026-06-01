open Core

module PhysAddr : sig 
    type t

    val of_int : int -> t
    val to_int : t -> int
end = struct
    type t = int

    let of_int x = x
    let to_int x = x
end

(**
   Page numbers represent the ordering of sectors within files
   **)
module PageNo : sig 
    type t [@@deriving compare]

    val of_int : int -> t
    val to_int : t -> int
    val is_data_page : t -> bool
end = struct
    type t = int [@@deriving compare]

    let is_data_page pageno = pageno <> 0
    let of_int x = x
    let to_int x = x
end

(** 
    A virtual address is the logical position of the sector on the disk
    **)
module VirtAddr : sig 
    type t [@@deriving sexp]

    val of_int : int -> t
    val to_int : t -> int
end = struct
    type t = int [@@deriving sexp]

    let of_int x = x
    let to_int x = x
end
