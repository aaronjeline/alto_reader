open Core
open Alto_reader

let path = "./tdisk4.dsk"

let () = 
    let disk = Disk.Disk.of_file path in
    Disk.Disk.all_sectors disk
    |> Sequence.iteri ~f:(fun i sector -> 
            let label = Disk.Sector.label sector in
            let (~hex, ~chars)  = Disk.hexdump_words label in
            Printf.printf "%d: %s|%s\n" i hex chars
    )

