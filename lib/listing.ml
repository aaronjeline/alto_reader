open Core
open Words

(** 
    Library for listing the files in a file system
**)


let sys_dir_virtual_addr = 1

let sys_dir_fid disk =
    Disk.get_sector disk sys_dir_virtual_addr
    |> Disk.Sector.label
    |> Disk.Label.fid


type page_ref = { pageno: int; bytes: int; data : Bigstring.t }

let compare_page_ref r1 r2 = 
    Int.compare r1.pageno r2.pageno

(** Determine if a sector belongs to a given fid, 
    and if so, return it's page number, bytes, and data page 
**)
let sector_belongs fid sector : page_ref option = 
    let label = Disk.Sector.label sector in
    if Disk.Fid.equal (Disk.Label.fid label) fid then
        Some {
            pageno = Disk.Label.page_number label;
            bytes = Disk.Label.nbytes label;
            data = Disk.Sector.data sector;
        }
    else
        None

let pages_of_file disk ~fid =
    Disk.all_sectors disk
    |> Sequence.filter_map ~f:(sector_belongs fid)
    |> Sequence.to_list

let concat_data_pages (pages : page_ref list)  =
    let data_pages =
        List.filter pages ~f:(fun r -> r.pageno > 0)
        |> List.sort ~compare:compare_page_ref
    in
    let total = List.fold data_pages ~init:0 ~f:(fun acc r -> acc + r.bytes) in
    let out = Bigstring.create total in
    let pos = ref 0 in
    List.iter data_pages ~f:(fun r ->
        Bigstring.blit 
            ~src:r.data 
            ~src_pos:0 
            ~dst:out 
            ~dst_pos:!pos 
            ~len:r.bytes;
        pos := !pos + r.bytes);
    out

let parse_entries buf =
    let n_words = Bigstring.length buf / bytes_per_word in
    (* TODO: replace this with a vector *)
    let out = ref [] in
    let i = ref 0 in
    let stop = ref false in
    while not !stop && !i < n_words do
        let hdr = read_word buf ~pos:(!i * bytes_per_word) in
        let type_field = (hdr lsr 10) land 0x3f in
        let length = hdr land 0x3ff in
        if length = 0 then stop := true
        else begin
            if type_field = Disk.Dv_entry.type_file then begin
                let leader_vda =
                    read_word buf
                        ~pos:((!i + Disk.Dv_entry.leader_vda_word_offset)
                              * bytes_per_word)
                in
                let name =
                    Bcpl_string.read buf
                        ~word_offset:(!i + Disk.Dv_entry.name_word_offset)
                in
                let f : File.t = { name; leader_vda } in
                out := f :: !out
            end;
            i := !i + length
        end
    done;
    List.rev !out

(**
    Traverse all the file entries in the root dir of the disk
**)
let files disk =
    let fid = sys_dir_fid disk in
    let pages = pages_of_file disk ~fid in
    let stream = concat_data_pages pages in
    parse_entries stream

let list_files disk = files disk |> List.map ~f:(fun f -> f.name)

let find_file disk ~name =
    files disk |> List.find ~f:(fun f -> String.equal f.name name)
