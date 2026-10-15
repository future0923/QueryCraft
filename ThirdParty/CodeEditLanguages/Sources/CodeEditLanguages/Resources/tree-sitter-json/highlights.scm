(pair
  key: (_) @property)

; Keep a completed key colored while its object/array value is still being typed.
(ERROR (string) @property . ":")

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @boolean

(escape_sequence) @type_alternate

(comment) @comment

["{" "}" "[" "]"] @punctuation.bracket
[":" ","] @punctuation.delimiter
