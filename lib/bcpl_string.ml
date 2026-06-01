open Core
open Words

(* BCPL strings are packed two bytes per word, with byte 0 (the length byte)
   in the HIGH half of the first word, byte 1 in the LOW half, etc. *)

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
