open Core
open Words
open Units

(** 
    Library for listing the files in a file system
**)

let sys_dir_file : File.t = {
    name = "";
    leader_vda = VirtAddr.of_int 1
}


(** parse the contents of a directory **)
let parse_entries buf =
    let n_words = Bigstring.length buf / bytes_per_word in
    let out = Vec.create () in
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
                     |> VirtAddr.of_int 
                in
                let name =
                    Bcpl_string.read buf
                        ~word_offset:(!i + Disk.Dv_entry.name_word_offset)
                in
                let f : File.t = { name; leader_vda } in
                Vec.push_back out f;
            end;
            i := !i + length
        end
    done;
    Vec.to_iarray out

(**
    Traverse all the file entries in the root dir of the disk
**)
let files disk =
    (* Get the data entries in the directory, then parse it *)
    File.concat_data_pages disk sys_dir_file
    |> parse_entries

let list_files disk = files disk |> Iarray.map ~f:(fun f -> f.name)

let find_file disk ~name =
    files disk |> Iarray.find ~f:(fun f -> String.equal f.name name)
