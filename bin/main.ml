open Core
open Alto_reader

let disk_path = "./tdisk4.dsk"

let editor () =
    match Sys.getenv "EDITOR" with
    | Some e when not (String.is_empty e) -> e
    | _ -> "vim"

let cmd_ls =
    Command.basic
      ~summary:"list files in SysDir"
      (Command.Param.return (fun () ->
           let disk = Disk.of_file disk_path in
           Listing.list_files disk |> Iarray.iter ~f:print_endline))

let cmd_edit =
    Command.basic
      ~summary:"open NAME in $EDITOR and write back on save"
      (let%map_open.Command name = Command.Param.anon ("NAME" %: Command.Param.string) in
       fun () ->
           let disk = Disk.of_file disk_path in
           match Listing.find_file disk ~name with
           | None ->
               eprintf "no such file: %s\n" name;
               exit 1
           | Some file ->
               let data = File.read disk file in
               let tmp = Filename_unix.temp_file "alto_edit_" "" in
               Out_channel.write_all tmp ~data:(Bytes.to_string data);
               let cmd = Printf.sprintf "%s %s" (editor ()) (Filename.quote tmp) in
               let rc = Sys_unix.command cmd in
               if rc <> 0 then begin
                   eprintf "editor exited with status %d; not writing back\n" rc;
                   Core_unix.unlink tmp;
                   exit rc
               end;
               let new_data = In_channel.read_all tmp |> Bytes.of_string in
               Core_unix.unlink tmp;
               File.write disk file new_data;
               printf "wrote %d bytes back to %s\n" (Bytes.length new_data) name)

let () =
    Command_unix.run
      (Command.group
         ~summary:"Alto disk image reader/editor"
         [ "ls",   cmd_ls
         ; "edit", cmd_edit
         ])
