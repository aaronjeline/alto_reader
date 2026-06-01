open Core

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
