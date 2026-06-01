open Core
open Words

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
