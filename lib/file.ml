open Core
open Words 

(** A file reference 
    Gives you the virtual address of a the first page in a file
 **)
type t = { name : string; leader_vda : int } [@@deriving sexp]

let leader_sector disk file = Disk.get_sector disk file.leader_vda

let fid disk file =
    leader_sector disk file
    |> Disk.Sector.label
    |> Disk.Label.fid

(** Is this a data page that belongs to the given fid? **)
let is_data_page file_fid sector = 
    let label = Disk.Sector.label sector in
    if Disk.Fid.equal (Disk.Label.fid label) file_fid
        && Disk.Label.is_data_page label then
            Some (~pageno:(Disk.Label.page_number label), sector)
    else
        None

(** All data pages of the file (page_number > 0), sorted ascending. **)
let data_pages disk file =
    let file_fid = fid disk file in
    Disk.all_sectors disk
    |> Sequence.filter_map  ~f:(is_data_page file_fid)
    |> Sequence.to_list
    |> List.sort 
        ~compare:(fun (~pageno:a, _) (~pageno:b, _) -> Int.compare a b)

(** read the raw bytes of a disk file **)        
let concat_data_pages disk file  =
    let pages = data_pages disk file in
    let bytes_in_sector sector = 
            sector 
            |> Disk.Sector.label 
            |> Disk.Label.nbytes in
    let total = 
        List.sum 
            (module Int) 
            ~f:(fun (~pageno, s) -> bytes_in_sector s)
            pages in
    let out = Bigstring.create total in
    let pos = ref 0 in
    List.iter pages ~f:(fun (~pageno, s) ->
        Bigstring.blit 
            ~src:(Disk.Sector.data s)
            ~src_pos:0 
            ~dst:out 
            ~dst_pos:!pos 
            ~len:(bytes_in_sector s);
        pos := !pos + (bytes_in_sector s));
    out

(* Bytes in the on-disk data area are stored swapped within each word
   pair: file byte 0 = low byte of word 0, file byte 1 = high byte, etc.
   The BCPL convention numbers bytes with byte 0 in the HIGH part of
   the word, so the natural byte at index [k] lives at page-byte index
   [k lxor 1]. We unswap on read and re-swap on write. *)

let read disk file =
    let pages = data_pages disk file in
    let total =
        List.fold pages ~init:0 ~f:(fun acc (~pageno, s) ->
            acc + Disk.Label.nbytes (Disk.Sector.label s))
    in
    let out = Bytes.create total in
    let pos = ref 0 in
    List.iter pages ~f:(fun (~pageno, sector) ->
        let nb = Disk.Label.nbytes (Disk.Sector.label sector) in
        let data = Disk.Sector.data sector in
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
            if Disk.Label.is_free (Disk.Sector.label sector) then (i, sector)
            else loop (i + 1)
    in
    loop 2

let write disk file new_data =
    let new_size = Bytes.length new_data in
    let existing = data_pages disk file in
    let n_existing = List.length existing in
    let n_needed = pages_needed new_size in
    let file_fid = fid disk file in
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
                let label = Disk.Sector.label sector in
                Disk.Label.set_fid label file_fid;
                Disk.Label.set_page_number label page_num;
                Disk.Label.set_blank label 0;
                extras := (~pageno:page_num, sector) :: !extras
            done;
            existing @ List.rev !extras
        end
    in
    let n_pages = List.length pages in
    (* Copy data into the pages, set per-page nbytes. *)
    let pos = ref 0 in
    List.iteri pages ~f:(fun idx (~pageno, sector) ->
        let label = Disk.Sector.label sector in
        let data = Disk.Sector.data sector in
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
        Disk.Label.set_nbytes label nb;
        pos := !pos + nb);
    (* Fix up the doubly-linked next/prev chain. The leader page links to
       page 1 (which we don't touch here); each data page's prev points to
       the previous data page (or the leader for page 1), and next points
       to the next data page (or 0 for the last). *)
    let leader_da = Disk.Sector.real_disk_address (leader_sector disk file) in
    let real_of (~pageno, sector) = Disk.Sector.real_disk_address sector in
    List.iteri pages ~f:(fun idx (~pageno, sector) ->
        let label = Disk.Sector.label sector in
        let prev_da =
            if idx = 0 then leader_da
            else real_of (List.nth_exn pages (idx - 1))
        in
        let next_da =
            if idx = n_pages - 1 then 0
            else real_of (List.nth_exn pages (idx + 1))
        in
        Disk.Label.set_prev label prev_da;
        Disk.Label.set_next label next_da);
    (* Release any pages no longer needed. *)
    if n_existing > n_needed then begin
        let to_free = List.drop existing n_needed in
        List.iter to_free ~f:(fun (~pageno, sector) ->
            let label = Disk.Sector.label sector in
            Disk.Label.set_fid label Disk.Fid.free;
            Disk.Label.set_nbytes label 0;
            Disk.Label.set_next label 0;
            Disk.Label.set_prev label 0;
            Disk.Label.set_page_number label 0)
    end
