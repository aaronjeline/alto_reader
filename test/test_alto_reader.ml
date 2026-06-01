open Core
open Alto_reader

(* dune's (deps ../tdisk4.dsk) puts the file at _build/default/tdisk4.dsk;
   the inline-test runner's cwd is _build/default/test, so this relative
   path resolves correctly. *)
let disk_image_path = "../tdisk4.dsk"

let with_disk_copy f =
  let tmp = Filename_unix.temp_file "alto_test" ".dsk" in
  let src_bytes = In_channel.read_all disk_image_path in
  Out_channel.write_all tmp ~data:src_bytes;
  let disk = Disk.Disk.of_file tmp in
  Exn.protect
    ~f:(fun () -> f disk)
    ~finally:(fun () -> Core_unix.unlink tmp)

let test_file_name = "user.cm."

let%test_unit "find_entry locates user.cm" =
  with_disk_copy (fun disk ->
    let entry = Disk.Listing.find_entry disk ~name:test_file_name in
    [%test_pred: Disk.Listing.entry option] Option.is_some entry)

let%test_unit "File.read returns non-empty data" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:test_file_name |> Option.value_exn
    in
    let data = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_pred: int] (fun n -> n > 0) (Bytes.length data))

(* "com.cm." is the Alto Executive startup command — known content " Quit.~\r".
   This catches a missing byte-pair swap (raw bytes would read "Q iu.t.~"). *)
let%test_unit "File.read decodes com.cm to its known content" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:"com.cm." |> Option.value_exn
    in
    let data = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_eq: string] " Quit.~\r" (Bytes.to_string data))

(* Round-trip a known string through write+read; confirms swap on write
   is the inverse of swap on read. *)
let%test_unit "write+read round-trips an arbitrary ASCII string" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:"com.cm." |> Option.value_exn
    in
    let payload = "hello world from ocaml\n" in
    Disk.File.write disk ~leader_vda:entry.leader_vda
      (Bytes.of_string payload);
    let back = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_eq: string] payload (Bytes.to_string back))

let%test_unit "round-trip: write same data is idempotent" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:test_file_name |> Option.value_exn
    in
    let original = Disk.File.read disk ~leader_vda:entry.leader_vda in
    Disk.File.write disk ~leader_vda:entry.leader_vda original;
    let back = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_eq: string] (Bytes.to_string original) (Bytes.to_string back))

let%test_unit "shrink within existing pages" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:test_file_name |> Option.value_exn
    in
    let original = Disk.File.read disk ~leader_vda:entry.leader_vda in
    let shrunk =
      Bytes.sub original ~pos:0 ~len:(Bytes.length original / 2)
    in
    Disk.File.write disk ~leader_vda:entry.leader_vda shrunk;
    let back = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_eq: string] (Bytes.to_string shrunk) (Bytes.to_string back))

let%test_unit "shrink to empty" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:test_file_name |> Option.value_exn
    in
    Disk.File.write disk ~leader_vda:entry.leader_vda (Bytes.create 0);
    let back = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_eq: int] 0 (Bytes.length back))

let%test_unit "grow file (allocate new pages from free list)" =
  with_disk_copy (fun disk ->
    let entry =
      Disk.Listing.find_entry disk ~name:test_file_name |> Option.value_exn
    in
    let original = Disk.File.read disk ~leader_vda:entry.leader_vda in
    (* Triple the data — likely needs new pages. *)
    let n = Bytes.length original in
    let grown = Bytes.create (n * 3) in
    Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:0 ~len:n;
    Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:n ~len:n;
    Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:(2 * n) ~len:n;
    Disk.File.write disk ~leader_vda:entry.leader_vda grown;
    let back = Disk.File.read disk ~leader_vda:entry.leader_vda in
    [%test_eq: string] (Bytes.to_string grown) (Bytes.to_string back))

let%test_unit "other files are not corrupted by a grow" =
  with_disk_copy (fun disk ->
    let other_name = "ALTODEFS.D." in
    let other =
      Disk.Listing.find_entry disk ~name:other_name |> Option.value_exn
    in
    let original_other =
      Disk.File.read disk ~leader_vda:other.leader_vda
    in
    let entry =
      Disk.Listing.find_entry disk ~name:test_file_name |> Option.value_exn
    in
    let original = Disk.File.read disk ~leader_vda:entry.leader_vda in
    let n = Bytes.length original in
    let grown = Bytes.create (n * 4) in
    for i = 0 to 3 do
      Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:(i * n) ~len:n
    done;
    Disk.File.write disk ~leader_vda:entry.leader_vda grown;
    let other_after = Disk.File.read disk ~leader_vda:other.leader_vda in
    [%test_eq: string]
      (Bytes.to_string original_other)
      (Bytes.to_string other_after))
