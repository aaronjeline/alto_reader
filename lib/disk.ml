open Core
module Unix = Core_unix

let word_size = 16

let words n = (n * word_size) / 8

let char_of_int i = 
    (let open Option.Let_syntax in
    let%bind c = Char.of_int i in
    if Char.is_print c then
        Some c
    else
        None)
    |> Option.value ~default:'.'

let hexdump_words buf = 
    assert (Bigstring.length buf mod 2 = 0);
    let words = Bigstring.length buf / 2  in
    let arr_hex = Array.create ~len:words "" in
    let arr_char = Array.create ~len:(2 * words) ' ' in
    for i = 0 to words - 1 do
        let word = Bigstring.get_uint16_be buf ~pos:(i * 2) in
        let hex = Printf.sprintf "%04X"  word in
        let char_b = char_of_int @@ Bigstring.get_uint8 buf ~pos:(i * 2) in
        let char_a = char_of_int @@  Bigstring.get_uint8 buf ~pos:(i * 2 + 1) in
        arr_char.(i * 2) <- char_a;
        arr_char.(i * 2 + 1) <- char_b;
        arr_hex.(i) <- hex;
    done;
    (~hex:(String.concat_array arr_hex ~sep:" "), 
    ~chars:(String.of_array arr_char))

module Sector : sig 
    type t

    val sector_size : int

    val create : Bigstring.t -> pos:int -> t

    val header : t -> Bigstring.t
    val label : t -> Bigstring.t
    val data : t -> Bigstring.t

end = struct
    type t = Bigstring.t

    let sector_size = 2 + 8 + 256

    let create buf ~pos = 
        Bigstring.sub_shared ~pos ~len:sector_size buf

    let header buf = 
        Bigstring.sub_shared ~pos:0 ~len:(words 2) buf

    let label buf = 
        Bigstring.sub_shared ~pos:(words 2) ~len:(words 8) buf

    let data buf = 
        Bigstring.sub_shared ~pos:((words 2) + (words 8)) ~len:(words 256) buf

end

module Disk = struct
    type t = { 
        buf : Bigstring.t;
        len : int
    }
    [@@deriving sexp]

    let of_file filename = 
        let f = Unix.openfile filename ~mode:[Unix.O_RDWR] in
        let stat = Unix.fstat f in
        let len = Int64.to_int_exn stat.st_size  in
        let buf = Bigstring_unix.map_file ~shared:false f len in
        { len; buf }

    let get_sector disk sector_num = 
        Sector.create disk.buf ~pos:(sector_num * Sector.sector_size)

    let all_sectors disk = 
        let sectors = disk.len mod Sector.sector_size in
        Sequence.range 0 sectors
        |> Sequence.map ~f:(get_sector disk)

end

