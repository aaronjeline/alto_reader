open Core
module Unix = Core_unix

(* See FORMAT.md for a description of the on-disk layout.

   Each sector is 267 16-bit words = 534 bytes:
     word[0]      - leading pad (always 0)
     word[1..2]   - 2-word header (word[2] = real disk address of this sector)
     word[3..10]  - 8-word label
     word[11..266] - 256-word data page

   Words are stored little-endian in the file. *)

let pad_words   = 1
let header_words = 2
let label_words  = 8
let data_words   = 256
let sector_words = pad_words + header_words + label_words + data_words
let bytes_per_word = 2
let sector_bytes = sector_words * bytes_per_word

let label_byte_offset = (pad_words + header_words) * bytes_per_word
let data_byte_offset  = (pad_words + header_words + label_words) * bytes_per_word
let real_da_byte_offset = (pad_words + 1) * bytes_per_word  (* word[2] *)

let bytes_per_data_page = data_words * bytes_per_word

let read_word  buf ~pos     = Bigstring.get_uint16_le buf ~pos
let write_word buf ~pos v   = Bigstring.set_uint16_le_exn buf ~pos v

let char_of_int i =
    (let open Option.Let_syntax in
    let%bind c = Char.of_int i in
    if Char.is_print c then
        Some c
    else
        None)
    |> Option.value ~default:'.'

let hexdump_words buf =
    assert (Bigstring.length buf mod bytes_per_word = 0);
    let words = Bigstring.length buf / bytes_per_word in
    let arr_hex = Array.create ~len:words "" in
    let arr_char = Array.create ~len:(2 * words) ' ' in
    for i = 0 to words - 1 do
        let word = read_word buf ~pos:(i * bytes_per_word) in
        let lo = word land 0xff in
        let hi = (word lsr 8) land 0xff in
        arr_hex.(i) <- Printf.sprintf "%04X" word;
        arr_char.(2 * i)     <- char_of_int hi;
        arr_char.(2 * i + 1) <- char_of_int lo;
    done;
    (~hex:(String.concat_array arr_hex ~sep:" "),
     ~chars:(String.of_array arr_char))

module Fid = struct
    type t = int * int * int [@@deriving sexp]

    let equal (a, b, c) (x, y, z) = a = x && b = y && c = z
    let free = (0xFFFF, 0xFFFF, 0xFFFF)
    let bad  = (0xFFFE, 0xFFFE, 0xFFFE)
end

module Label : sig
    type t

    val of_bigstring : Bigstring.t -> t

    val next        : t -> int
    val prev        : t -> int
    val blank       : t -> int
    val nbytes      : t -> int
    val page_number : t -> int
    val fid         : t -> Fid.t

    val is_free : t -> bool
    val is_bad  : t -> bool

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
    let fid         t = (word_at t 5, word_at t 6, word_at t 7)

    let is_free t = Fid.equal (fid t) Fid.free
    let is_bad  t = Fid.equal (fid t) Fid.bad

    let set_next        t v = set_word_at t 0 v
    let set_prev        t v = set_word_at t 1 v
    let set_blank       t v = set_word_at t 2 v
    let set_nbytes      t v = set_word_at t 3 v
    let set_page_number t v = set_word_at t 4 v
    let set_fid t (a, b, c) =
        set_word_at t 5 a;
        set_word_at t 6 b;
        set_word_at t 7 c
end

module Sector : sig
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

module Disk = struct
    type t = {
        buf : Bigstring.t;
        len : int
    }
    [@@deriving sexp]

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
end

(* BCPL strings are packed two bytes per word, with byte 0 (the length byte)
   in the HIGH half of the first word, byte 1 in the LOW half, etc. *)
module Bcpl_string = struct
    let read buf ~word_offset =
        let word_at i = read_word buf ~pos:(i * bytes_per_word) in
        let length = (word_at word_offset lsr 8) land 0xff in
        let s = Bytes.create length in
        for k = 1 to length do
            let w = word_at (word_offset + (k / 2)) in
            let b =
                if k mod 2 = 0 then (w lsr 8) land 0xff
                else w land 0xff
            in
            Bytes.set s (k - 1) (Char.of_int_exn b)
        done;
        Bytes.to_string s
end

(* Directory entries in a DV (directory) file. Each entry begins with a single
   16-bit type+length word:
     type   = (word >> 10) & 0x3F   - 6-bit type
     length =  word & 0x3FF         - 10-bit length in WORDS

   For a file entry (type = 1):
     word 1     - reserved padding (always 0)
     word 2..4  - fid (3 words)
     word 5     - leaderVirtualDA
     word 6..   - BCPL filename string *)
module Dv_entry = struct
    let type_file = 1
    let leader_vda_word_offset = 5
    let name_word_offset = 6
end

module Listing = struct
    type entry = { name : string; leader_vda : int } [@@deriving sexp]

    let sys_dir_virtual_addr = 1

    let sys_dir_fid disk =
        Label.fid (Sector.label (Disk.get_sector disk sys_dir_virtual_addr))

    let pages_of_file disk ~fid =
        Disk.all_sectors disk
        |> Sequence.filter_map ~f:(fun sector ->
            let label = Sector.label sector in
            if Fid.equal (Label.fid label) fid then
                Some (Label.page_number label,
                      Label.nbytes label,
                      Sector.data sector)
            else None)
        |> Sequence.to_list

    let concat_data_pages pages =
        let data_pages =
            List.filter pages ~f:(fun (pg, _, _) -> pg > 0)
            |> List.sort ~compare:(fun (a, _, _) (b, _, _) -> Int.compare a b)
        in
        let total = List.fold data_pages ~init:0 ~f:(fun acc (_, nb, _) -> acc + nb) in
        let out = Bigstring.create total in
        let pos = ref 0 in
        List.iter data_pages ~f:(fun (_, nb, data) ->
            Bigstring.blit ~src:data ~src_pos:0 ~dst:out ~dst_pos:!pos ~len:nb;
            pos := !pos + nb);
        out

    let parse_entries buf =
        let n_words = Bigstring.length buf / bytes_per_word in
        let out = ref [] in
        let i = ref 0 in
        let stop = ref false in
        while not !stop && !i < n_words do
            let hdr = read_word buf ~pos:(!i * bytes_per_word) in
            let type_field = (hdr lsr 10) land 0x3f in
            let length = hdr land 0x3ff in
            if length = 0 then stop := true
            else begin
                if type_field = Dv_entry.type_file then begin
                    let leader_vda =
                        read_word buf
                            ~pos:((!i + Dv_entry.leader_vda_word_offset)
                                  * bytes_per_word)
                    in
                    let name =
                        Bcpl_string.read buf
                            ~word_offset:(!i + Dv_entry.name_word_offset)
                    in
                    out := { name; leader_vda } :: !out
                end;
                i := !i + length
            end
        done;
        List.rev !out

    let entries disk =
        let fid = sys_dir_fid disk in
        let pages = pages_of_file disk ~fid in
        let stream = concat_data_pages pages in
        parse_entries stream

    let list_files disk = entries disk |> List.map ~f:(fun e -> e.name)

    let find_entry disk ~name =
        entries disk |> List.find ~f:(fun e -> String.equal e.name name)
end

module File = struct
    let leader_sector disk ~leader_vda = Disk.get_sector disk leader_vda

    let fid disk ~leader_vda =
        Label.fid (Sector.label (leader_sector disk ~leader_vda))

    (* All data pages of the file (page_number > 0), sorted ascending. *)
    let data_pages disk ~leader_vda =
        let file_fid = fid disk ~leader_vda in
        Disk.all_sectors disk
        |> Sequence.filter_map ~f:(fun sector ->
            let label = Sector.label sector in
            if Fid.equal (Label.fid label) file_fid
                && Label.page_number label > 0
            then Some (Label.page_number label, sector)
            else None)
        |> Sequence.to_list
        |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)

    (* Bytes in the on-disk data area are stored swapped within each word
       pair: file byte 0 = low byte of word 0, file byte 1 = high byte, etc.
       The BCPL convention numbers bytes with byte 0 in the HIGH part of
       the word, so the natural byte at index [k] lives at page-byte index
       [k lxor 1]. We unswap on read and re-swap on write. *)

    let read disk ~leader_vda =
        let pages = data_pages disk ~leader_vda in
        let total =
            List.fold pages ~init:0 ~f:(fun acc (_, s) ->
                acc + Label.nbytes (Sector.label s))
        in
        let out = Bytes.create total in
        let pos = ref 0 in
        List.iter pages ~f:(fun (_, sector) ->
            let nb = Label.nbytes (Sector.label sector) in
            let data = Sector.data sector in
            for k = 0 to nb - 1 do
                Bytes.set out (!pos + k) (Bigstring.get data (k lxor 1))
            done;
            pos := !pos + nb);
        out

    (* Number of pages required to store [size] bytes. The last page must hold
       fewer than [bytes_per_data_page] bytes, so a size that's an exact
       multiple needs one extra (empty) trailing page. *)
    let pages_needed size =
        if size = 0 then 1
        else (size / bytes_per_data_page) + 1

    (* Find a sector whose label says it's free. Skips sector 0 (boot) and
       sector 1 (SysDir leader). *)
    let find_free_sector disk ~exclude =
        let n = Disk.n_sectors disk in
        let excluded = Set.of_list (module Int) exclude in
        let rec loop i =
            if i >= n then failwith "no free sectors on disk"
            else if Set.mem excluded i then loop (i + 1)
            else
                let sector = Disk.get_sector disk i in
                if Label.is_free (Sector.label sector) then (i, sector)
                else loop (i + 1)
        in
        loop 2

    let write disk ~leader_vda new_data =
        let new_size = Bytes.length new_data in
        let existing = data_pages disk ~leader_vda in
        let n_existing = List.length existing in
        let n_needed = pages_needed new_size in
        let file_fid = fid disk ~leader_vda in
        (* Build the final list of pages used. Reuse existing pages first,
           then allocate from free list if we need more. *)
        let pages =
            if n_needed <= n_existing then
                List.take existing n_needed
            else begin
                let extras = ref [] in
                (* Don't pick a sector that's already one of [existing] — the
                   labels won't read as "free" once we start filling earlier
                   pages, but it's clearer to exclude them upfront. *)
                let excluded = ref [] in
                for page_num = n_existing + 1 to n_needed do
                    let (v, sector) =
                        find_free_sector disk ~exclude:!excluded
                    in
                    excluded := v :: !excluded;
                    (* Claim the page: set fid + page number so it stops
                       reading as free for subsequent allocations. *)
                    let label = Sector.label sector in
                    Label.set_fid label file_fid;
                    Label.set_page_number label page_num;
                    Label.set_blank label 0;
                    extras := (page_num, sector) :: !extras
                done;
                existing @ List.rev !extras
            end
        in
        let n_pages = List.length pages in
        (* Copy data into the pages, set per-page nbytes. *)
        let pos = ref 0 in
        List.iteri pages ~f:(fun idx (_, sector) ->
            let label = Sector.label sector in
            let data = Sector.data sector in
            let nb =
                if idx = n_pages - 1 then new_size - !pos
                else bytes_per_data_page
            in
            for k = 0 to nb - 1 do
                Bigstring.set data (k lxor 1) (Bytes.get new_data (!pos + k))
            done;
            (* If nb is odd, the low byte of the last word in use is the
               BCPL "garbage byte" (page-byte index nb-1) — zero it. *)
            if nb land 1 = 1 then Bigstring.set data (nb - 1) '\x00';
            Label.set_nbytes label nb;
            pos := !pos + nb);
        (* Fix up the doubly-linked next/prev chain. The leader page links to
           page 1 (which we don't touch here); each data page's prev points to
           the previous data page (or the leader for page 1), and next points
           to the next data page (or 0 for the last). *)
        let leader_da = Sector.real_disk_address (leader_sector disk ~leader_vda) in
        let real_of (_, sector) = Sector.real_disk_address sector in
        List.iteri pages ~f:(fun idx (_, sector) ->
            let label = Sector.label sector in
            let prev_da =
                if idx = 0 then leader_da
                else real_of (List.nth_exn pages (idx - 1))
            in
            let next_da =
                if idx = n_pages - 1 then 0
                else real_of (List.nth_exn pages (idx + 1))
            in
            Label.set_prev label prev_da;
            Label.set_next label next_da);
        (* Release any pages no longer needed. *)
        if n_existing > n_needed then begin
            let to_free = List.drop existing n_needed in
            List.iter to_free ~f:(fun (_, sector) ->
                let label = Sector.label sector in
                Label.set_fid label Fid.free;
                Label.set_nbytes label 0;
                Label.set_next label 0;
                Label.set_prev label 0;
                Label.set_page_number label 0)
        end
end
