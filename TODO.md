- Common Lisp has that `()` and `'nil` always act the same, including `(block nil (return-from ()))` and so on
  - Currently, only `(return-from ())` -> `(return-from nil)` rewriting is supported
- Loops!
- Rest parameters currently work via dotted lists, should move to `&rest`
- Optional params via `&optional`
- Move some things into a standard library:
  - `(defmacro return (&optional val) (list 'return-from nil val))`
  - `(defun list (&rest xs) xs)`