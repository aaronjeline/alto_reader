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
  let disk = Disk.of_file tmp in
  Exn.protect
    ~f:(fun () -> f disk)
    ~finally:(fun () -> Core_unix.unlink tmp)

let test_file_name = "user.cm."

let%test_unit "find_file locates user.cm" =
  with_disk_copy (fun disk ->
    let file = Listing.find_file disk ~name:test_file_name in
    [%test_pred: File.t option] Option.is_some file)

let%test_unit "File.read returns non-empty data" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:test_file_name |> Option.value_exn
    in
    let data = File.read disk file in
    [%test_pred: int] (fun n -> n > 0) (Bytes.length data))

(* "com.cm." is the Alto Executive startup command — known content " Quit.~\r".
   This catches a missing byte-pair swap (raw bytes would read "Q iu.t.~"). *)
let%test_unit "File.read decodes com.cm to its known content" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:"com.cm." |> Option.value_exn
    in
    let data = File.read disk file in
    [%test_eq: string] " Quit.~\r" (Bytes.to_string data))

(* Round-trip a known string through write+read; confirms swap on write
   is the inverse of swap on read. *)
let%test_unit "write+read round-trips an arbitrary ASCII string" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:"com.cm." |> Option.value_exn
    in
    let payload = "hello world from ocaml\n" in
    File.write disk file
      (Bytes.of_string payload);
    let back = File.read disk file in
    [%test_eq: string] payload (Bytes.to_string back))

let%test_unit "round-trip: write same data is idempotent" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:test_file_name |> Option.value_exn
    in
    let original = File.read disk file in
    File.write disk file original;
    let back = File.read disk file in
    [%test_eq: string] (Bytes.to_string original) (Bytes.to_string back))

let%test_unit "shrink within existing pages" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:test_file_name |> Option.value_exn
    in
    let original = File.read disk file in
    let shrunk =
      Bytes.sub original ~pos:0 ~len:(Bytes.length original / 2)
    in
    File.write disk file shrunk;
    let back = File.read disk file in
    [%test_eq: string] (Bytes.to_string shrunk) (Bytes.to_string back))

let%test_unit "shrink to empty" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:test_file_name |> Option.value_exn
    in
    File.write disk file (Bytes.create 0);
    let back = File.read disk file in
    [%test_eq: int] 0 (Bytes.length back))

let%test_unit "grow file (allocate new pages from free list)" =
  with_disk_copy (fun disk ->
    let file =
      Listing.find_file disk ~name:test_file_name |> Option.value_exn
    in
    let original = File.read disk file in
    (* Triple the data — likely needs new pages. *)
    let n = Bytes.length original in
    let grown = Bytes.create (n * 3) in
    Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:0 ~len:n;
    Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:n ~len:n;
    Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:(2 * n) ~len:n;
    File.write disk file grown;
    let back = File.read disk file in
    [%test_eq: string] (Bytes.to_string grown) (Bytes.to_string back))

let%test_unit "other files are not corrupted by a grow" =
  with_disk_copy (fun disk ->
    let other_name = "ALTODEFS.D." in
    let other =
      Listing.find_file disk ~name:other_name |> Option.value_exn
    in
    let original_other =
      File.read disk other
    in
    let file =
      Listing.find_file disk ~name:test_file_name |> Option.value_exn
    in
    let original = File.read disk file in
    let n = Bytes.length original in
    let grown = Bytes.create (n * 4) in
    for i = 0 to 3 do
      Bytes.blit ~src:original ~src_pos:0 ~dst:grown ~dst_pos:(i * n) ~len:n
    done;
    File.write disk file grown;
    let other_after = File.read disk other in
    [%test_eq: string]
      (Bytes.to_string original_other)
      (Bytes.to_string other_after))
