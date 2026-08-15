;;; ess-view-data-test.el --- ERT tests for ess-view-data -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT test suite for ess-view-data.
;;
;; Run in CI with `eldev test'.  Locally (when eldev is unavailable):
;;   emacs -Q --batch -l <run-tests.el>
;;
;; Tests in this file only exercise pure Emacs Lisp code; they never
;; start an R process.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ess-view-data)

(ert-deftest ess-view-data-test-smoke ()
  "Smoke test: package loads and core entry points exist."
  (should (fboundp 'ess-view-data-print))
  (should (fboundp 'ess-view-data-verbs))
  (should (boundp 'ess-view-data-rows-per-page))
  (should (eq ess-view-data-current-backend 'dplyr)))

(ert-deftest ess-view-data-test-page-total ()
  "Page count is ceiling(nrow / rpp), always at least 1 (A1/A2)."
  (let ((rpp 200))
    (should (= 1 (ess-view-data--page-total 0 rpp)))
    (should (= 1 (ess-view-data--page-total 1 rpp)))
    (should (= 1 (ess-view-data--page-total 200 rpp)))
    (should (= 2 (ess-view-data--page-total 201 rpp)))
    (should (= 2 (ess-view-data--page-total 400 rpp)))))

(ert-deftest ess-view-data-test-page-slice ()
  "Slice string is nil for empty/out-of-range pages, else [start:end,] (A2)."
  (let ((rpp 200))
    ;; empty data: never slice
    (should (null (ess-view-data--page-slice 0 rpp 0)))
    ;; single row on page 0
    (should (equal "[1:1,]" (ess-view-data--page-slice 0 rpp 1)))
    ;; exactly one page of 200 rows
    (should (equal "[1:200,]" (ess-view-data--page-slice 0 rpp 200)))
    ;; second page of 201 rows holds only row 201
    (should (equal "[201:201,]" (ess-view-data--page-slice 1 rpp 201)))
    ;; second page of 400 rows holds rows 201-400
    (should (equal "[201:400,]" (ess-view-data--page-slice 1 rpp 400)))
    ;; page 1 does not exist when nrow is an exact multiple of rpp
    (should (null (ess-view-data--page-slice 1 rpp 200)))))

(ert-deftest ess-view-data-test-page-slice-expr ()
  "Guarded R slice expression guards nrow < 1 and uses 0-based pages."
  (should (equal
           "[if (nrow(temp) < 1) integer(0) else (0*200 + 1):min((0 + 1)*200, nrow(temp)),]"
           (ess-view-data--page-slice-expr 0 200 "temp")))
  (should (equal
           "[if (nrow(`temp`) < 1) integer(0) else (1*200 + 1):min((1 + 1)*200, nrow(`temp`)),]"
           (ess-view-data--page-slice-expr 1 200 "`temp`"))))

(ert-deftest ess-view-data-test-r-quote-string ()
  "R string literal quoting: forward slashes and escaped double quotes (A5)."
  (should (equal "\"C:/data/file.csv\""
                 (ess-view-data--r-quote-string "C:\\data\\file.csv")))
  (should (equal "\"a\\\"b\"" (ess-view-data--r-quote-string "a\"b")))
  (should (equal "\"plain\"" (ess-view-data--r-quote-string "plain"))))

(ert-deftest ess-view-data-test-dplyr-codegen ()
  "dplyr verb history strings are built as expected."
  (should (equal " %>% dplyr::select(mpg,cyl)"
                 (car (ess-view-data--do-update 'dplyr 'select '("cyl" "mpg")))))
  (should (equal " %>% dplyr::arrange(cyl, .by_group = TRUE)"
                 (car (ess-view-data--do-update 'dplyr 'sort '("cyl")))))
  (should (equal " %>% dplyr::filter(cyl > 4)"
                 (car (ess-view-data--do-update 'dplyr 'filter "cyl > 4"))))
  (should (equal " %>% dplyr::count(cyl)"
                 (car (ess-view-data--do-summarise 'dplyr 'count '("cyl")))))
  (should (equal " %>% skimr::skim(cyl)"
                 (car (ess-view-data--do-summarise 'dplyr 'skimr '("cyl")))))
  (should (equal " %>% skimr::skim()"
                 (car (ess-view-data--do-summarise 'dplyr 'skimr-all nil)))))

(ert-deftest ess-view-data-test-dt-codegen ()
  "dplyr+DT verb history strings and data.table count (A10)."
  (let ((ess-view-data-temp-object "temp")
        (ess-view-data-maxprint-p nil)
        (ess-view-data-cache-directory "/tmp/evd"))
    (should (equal " %>% tidyr::gather(a, b)"
                   (car (ess-view-data--do-update 'dplyr+DT 'wide2long "a, b"))))
    (should (equal " %>% tidyr::spread(a, b)"
                   (car (ess-view-data--do-update 'dplyr+DT 'long2wide "a, b"))))
    (should (equal " %>% .[, .N, by = .(cyl)] "
                   (car (ess-view-data--do-summarise
                         'data.table+magrittr 'count '("cyl")))))))

(ert-deftest ess-view-data-test-data-table-summarise-backend ()
  "data.table summarise honours the summarise print backend (A8)."
  (let ((ess-view-data-temp-object "temp")
        (ess-view-data-display-backend 'print))
    (let ((ess-view-data-current-summarise-print-backend 'kable))
      (should (string-match-p
               "knitr::kable"
               (cdr (ess-view-data--do-summarise
                     'data.table+magrittr 'count '("cyl"))))))
    (let ((ess-view-data-current-summarise-print-backend 'print))
      (should-not (string-match-p
                   "knitr::kable"
                   (cdr (ess-view-data--do-summarise
                         'data.table+magrittr 'count '("cyl")))))
      (should (string-match-p
               "n = nrow(temp)"
               (cdr (ess-view-data--do-summarise
                     'data.table+magrittr 'count '("cyl"))))))))

(ert-deftest ess-view-data-test-verb-table-dplyr-kinds ()
  "Every verb-table kind produces the expected snippet for dplyr."
  (should (equal " %>% dplyr::select(-mpg,-cyl)"
                 (ess-view-data--verb-code 'dplyr 'unselect '("cyl" "mpg"))))
  (should (equal " %>% dplyr::mutate(x = 1)"
                 (ess-view-data--verb-code 'dplyr 'mutate "x = 1")))
  (should (equal " %>% dplyr::group_by(cyl)"
                 (ess-view-data--verb-code 'dplyr 'group '("cyl"))))
  (should (equal " %>% dplyr::ungroup(cyl)"
                 (ess-view-data--verb-code 'dplyr 'ungroup '("cyl"))))
  (should (equal " %>% dplyr::slice(1:3)"
                 (ess-view-data--verb-code 'dplyr 'slice "1:3")))
  (should (equal " %>% tidyr::pivot_longer(a:b)"
                 (ess-view-data--verb-code 'dplyr 'wide2long-pivot_longer "a:b")))
  (should (equal " %>% tidyr::pivot_wider(a:b)"
                 (ess-view-data--verb-code 'dplyr 'long2wide-pivot_wider "a:b")))
  ;; fixed kind ignores ACTION
  (should (equal " %>% skimr::skim()"
                 (ess-view-data--verb-code 'dplyr 'skimr-all nil)))
  ;; raw kind joins a list with ","
  (should (equal " %>% dplyr::filter(a > 1,b < 2)"
                 (ess-view-data--verb-code 'dplyr 'filter '("a > 1" "b < 2")))))

(ert-deftest ess-view-data-test-verb-table-data-table ()
  "data.table+magrittr verbs are generated from the verb table."
  (should (equal " %>% .[, .(mpg,cyl)]"
                 (ess-view-data--verb-code 'data.table+magrittr 'select '("cyl" "mpg"))))
  (should (equal " %>% setorder(., cyl)"
                 (ess-view-data--verb-code 'data.table+magrittr 'sort '("cyl"))))
  (should (equal " %>% .[cyl > 4,]"
                 (ess-view-data--verb-code 'data.table+magrittr 'filter "cyl > 4")))
  (should (equal " %>% .[,`:=`(mpg = NULL,cyl = NULL)]"
                 (ess-view-data--verb-code 'data.table+magrittr 'unselect '("cyl" "mpg"))))
  (should (equal " %>% .[, .N, by = .(cyl)] "
                 (ess-view-data--verb-code 'data.table+magrittr 'count '("cyl"))))
  (should (equal " %>% melt(., id.vars = a)"
                 (ess-view-data--verb-code 'data.table+magrittr 'wide2long "id.vars = a")))
  (should (equal " %>% dcast(., a ~ b)"
                 (ess-view-data--verb-code 'data.table+magrittr 'long2wide "a ~ b")))
  ;; unique unwraps backquoted column names
  (should (equal " %>% unique(., by = c(\"mpg\",\"cyl\"))"
                 (ess-view-data--verb-code 'data.table+magrittr 'unique '("`cyl`" "`mpg`"))))
  ;; error kind signals on verbs without a data.table step
  (should-error (ess-view-data--verb-code 'data.table+magrittr 'ungroup nil)
                :type 'error))

(ert-deftest ess-view-data-test-verb-table-data-table-group-slice ()
  "data.table group stores columns and slice consumes them."
  (let ((ess-view-data--group nil))
    (should (null (ess-view-data--verb-code 'data.table+magrittr 'group '("cyl"))))
    (should (equal "cyl" ess-view-data--group))
    (should (equal " %>% .[, .SD[1:3], by = .(cyl)]"
                   (ess-view-data--verb-code 'data.table+magrittr 'slice "1:3"))))
  ;; slice without a prior group signals an error
  (let ((ess-view-data--group nil))
    (should-error (ess-view-data--verb-code 'data.table+magrittr 'slice "1:3")
                  :type 'error)))

(ert-deftest ess-view-data-test-verb-table-cross-backend ()
  "select keeps the same column order across backends."
  (should (equal " %>% dplyr::select(mpg,cyl)"
                 (ess-view-data--verb-code 'dplyr 'select '("cyl" "mpg"))))
  (should (equal " %>% dplyr::select(mpg,cyl)"
                 (ess-view-data--verb-code 'dplyr+DT 'select '("cyl" "mpg"))))
  (should (equal " %>% .[, .(mpg,cyl)]"
                 (ess-view-data--verb-code 'data.table+magrittr 'select '("cyl" "mpg")))))

(ert-deftest ess-view-data-test-table-command-only ()
  "Table display separates the data command from the rendering."
  (let ((ess-view-data-display-backend 'table)
        (ess-view-data-temp-object "temp"))
    ;; update returns the assignment without the embedded print
    (should (equal "temp <<- temp %>% dplyr::select(mpg,cyl); "
                   (cdr (ess-view-data--do-update 'dplyr 'select '("cyl" "mpg")))))
    ;; summarise returns no R command; the render object is the pipeline
    (let ((ess-view-data--render-object nil))
      (should (null (cdr (ess-view-data--do-summarise 'dplyr 'count '("cyl")))))
      (should (equal "temp %>% dplyr::count(cyl)" ess-view-data--render-object)))
    ;; update clears the summarise render object
    (let ((ess-view-data--render-object "temp %>% dplyr::count(cyl)"))
      (ess-view-data--do-update 'dplyr 'select '("cyl"))
      (should (null ess-view-data--render-object))))
  ;; text mode keeps the embedded rendering
  (let ((ess-view-data-display-backend 'print)
        (ess-view-data-temp-object "temp"))
    (should (string-match-p
             "local({"
             (cdr (ess-view-data--do-update 'dplyr 'select '("cyl")))))))

(ert-deftest ess-view-data-test-page-data ()
  "The protocol parser splits header lines and TAB-separated rows."
  (let ((d (ess-view-data--page-data
            (concat "EVD_N 3\n"
                    "EVD_ROWS 1\t2\t3\n"
                    "EVD_COLS mpg\tcyl\n"
                    "EVD_TYPES dbl\tdbl\n"
                    "21\t6\n"
                    "21\t6\n"
                    "22.8\t4\n"))))
    (should (equal 3 (nth 0 d)))
    (should (equal '("1" "2" "3") (nth 1 d)))
    (should (equal '("mpg" "cyl") (nth 2 d)))
    (should (equal '("dbl" "dbl") (nth 3 d)))
    (should (equal '(("21" "6") ("21" "6") ("22.8" "4")) (nth 4 d))))
  ;; an echoed command line before the protocol output is tolerated
  (let ((d (ess-view-data--page-data
            (concat "ess_view_data_page(temp)\n"
                    "EVD_N 1\n"
                    "EVD_ROWS 1\n"
                    "EVD_COLS x\n"
                    "EVD_TYPES chr\n"
                    "abc\n"))))
    (should (equal 1 (nth 0 d)))
    (should (equal '(("abc")) (nth 4 d)))))

(ert-deftest ess-view-data-test-page-data-empty ()
  "Empty data has no rows and no column payloads."
  (let ((d (ess-view-data--page-data
            (concat "EVD_N 0\nEVD_ROWS\nEVD_COLS\nEVD_TYPES\n"))))
    (should (equal 0 (nth 0 d)))
    (should (null (nth 1 d)))
    (should (null (nth 2 d)))
    (should (null (nth 3 d)))
    (should (null (nth 4 d)))))

(ert-deftest ess-view-data-test-page-data-error ()
  "A missing EVD_N header means the R expression errored."
  (should (null (ess-view-data--page-data
                 "Error in eval(substitute(expr)) : object 'x' not found"))))

(ert-deftest ess-view-data-test-protocol-cmd ()
  "The protocol query uses 1-based row ranges from the 0-based page."
  (let ((ess-view-data-temp-object "`temp`")
        (ess-view-data--render-object nil)
        (ess-view-data-page-number 2)
        (ess-view-data-rows-per-page 200))
    (should (equal "ess_view_data_page(`temp`, 401L, 600L)\n"
                   (ess-view-data--protocol-cmd)))))

(ert-deftest ess-view-data-test-table-format ()
  "Table format stores the raw name, widths and numeric alignment."
  (let ((ess-view-data-column-width-cap 16))
    (let ((fmt (ess-view-data--table-format
                '("mpg" "name") '("dbl" "chr") '(8 16))))
      (should (equal "mpg [dbl]" (car (aref fmt 0))))
      (should (equal 8 (nth 1 (aref fmt 0))))
      (should (equal "mpg" (plist-get (nthcdr 3 (aref fmt 0)) :evd-name)))
      (should (plist-get (nthcdr 3 (aref fmt 0)) :right-align))
      (should-not (plist-get (nthcdr 3 (aref fmt 1)) :right-align))))
    ;; cell widths are capped at the customisation
    (should (equal 16
                   (car (ess-view-data--table-widths
                         '("mpg") '("dbl")
                         '(("This is a very long value in the cell")))))))

(ert-deftest ess-view-data-test-table-cell-truncate ()
  "Cells longer than the column width get an ellipsis."
  (should (equal "abc..." (ess-view-data--table-cell "abcdefghij" 6)))
  (should (equal "abc" (ess-view-data--table-cell "abc" 6))))

(ert-deftest ess-view-data-test-completion-col-cache ()
  "Column names are cached; the first call adopts `--page-cols'."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "`mtcars`")
    (setq-local ess-view-data--page-cols '("mpg" "cyl"))
    ;; first call: page-cols are adopted with no R round trip
    (should (equal '("mpg" "cyl")
                   (ess-view-data--ensure-completion-cols)))
    ;; second call: served from the cache
    (should (equal '("mpg" "cyl")
                   (ess-view-data--ensure-completion-cols)))
    ;; dropping the page cache does not hurt once the name cache exists
    (setq-local ess-view-data--page-cols nil)
    (should (equal '("mpg" "cyl")
                   (ess-view-data--ensure-completion-cols)))))

(ert-deftest ess-view-data-test-completion-cols ()
  "`--completion-cols' returns the cached names of the temp object."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "`mtcars`")
    (setq ess-view-data-completion-candidate '((obj:mtcars "mpg" "cyl")))
    (should (equal '("mpg" "cyl") (ess-view-data--completion-cols)))))

(ert-deftest ess-view-data-test-completion-get-vector ()
  "`--completion-get' converts vector values for convenience."
  (with-temp-buffer
    (setq ess-view-data-completion-candidate '((col:cyl . ["4" "6" "8"])))
    (should (equal '("4" "6" "8") (ess-view-data--completion-get 'col:cyl)))))

(ert-deftest ess-view-data-test-completion-owner ()
  "The cache lives in the view buffer and is shared with edit buffers."
  (let (view)
    (with-temp-buffer
      (setq-local ess-view-data-temp-object "mtcars")
      (setq ess-view-data-completion-candidate '((obj:mtcars "mpg" "cyl")))
      (setq view (current-buffer))
      (with-temp-buffer
        ;; an edit buffer without a cache of its own, pointing at VIEW
        (setq-local ess-view-data--parent-buffer view)
        (setq-local ess-view-data-temp-object "mtcars")
        (should (null ess-view-data-completion-candidate))
        ;; reads resolve through the owner
        (should (equal '("mpg" "cyl") (ess-view-data--completion-get 'obj:mtcars)))
        ;; writes from the edit buffer land in the view buffer
        (ess-view-data--completion-put 'col:hp '("100" "200"))
        (should (equal '("100" "200")
                       (alist-get 'col:hp (buffer-local-value
                                           'ess-view-data-completion-candidate view))))
        ;; `--ensure-completion-cols' resolves and caches via the owner
        (should (equal '("mpg" "cyl") (ess-view-data--ensure-completion-cols)))
        (should (assq 'obj:mtcars (buffer-local-value
                                   'ess-view-data-completion-candidate view)))))))

(ert-deftest ess-view-data-test-completion-invalidate ()
  "`--invalidate-completion' drops both cache layers."
  (with-temp-buffer
    (setq ess-view-data-completion-candidate '((obj:mtcars "mpg" "cyl")))
    (setq-local ess-view-data--page-cols '("mpg" "cyl"))
    (ess-view-data--invalidate-completion (current-buffer))
    (should (null ess-view-data-completion-candidate))
    (should (null ess-view-data--page-cols))))

(ert-deftest ess-view-data-test-column-values-cache ()
  "Column values are cached per column; failed fetches are not cached."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "mtcars")
    ;; no R process attached: the fetch fails and must not be pinned
    (should (null (ess-view-data--column-values "mpg")))
    (should (null ess-view-data-completion-candidate))
    ;; once populated, later accesses hit the cache
    (ess-view-data--completion-put 'col:mpg '("21" "22"))
    (should (equal '("21" "22") (ess-view-data--column-values "mpg")))
    ;; a different column stays separate until populated
    (should (null (ess-view-data--column-values "cyl")))
    (should (equal '("21" "22") (ess-view-data--completion-get 'col:mpg)))))

(ert-deftest ess-view-data-test-do-complete-data-channels ()
  "do-complete-data builds the alist from column names and per-column values."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "mtcars")
    (setq-local ess-view-data--page-cols '("mpg" "cyl"))
    (ess-view-data--completion-put 'col:mpg '("21" "22"))
    (let ((result (ess-view-data-do-complete-data 'jsonlite)))
      (should (equal (cons 'mtcars '("mpg" "cyl")) (car result)))
      (should (equal '("21" "22") (cdr (assq 'mpg result))))
      ;; "cyl" has no process-backed fetch here, so its slot is empty
      (should (assq 'cyl result))
      (should (null (cdr (assq 'cyl result)))))))

(ert-deftest ess-view-data-test-completion-key-normalize ()
  "`--completion-key' namespaces object/column keys and strips backticks."
  (should (eq 'obj:mtcars (ess-view-data--completion-key 'object "`mtcars`")))
  (should (eq 'obj:mtcars (ess-view-data--completion-key 'object "mtcars")))
  (should (eq (intern "col:my col")
              (ess-view-data--completion-key 'column "`my col`")))
  ;; the two namespaces never collide
  (should-not (eq (ess-view-data--completion-key 'object "mtcars")
                  (ess-view-data--completion-key 'column "mtcars"))))

(ert-deftest ess-view-data-test-completion-empty-data ()
  "Empty data: no column names to cache, and fetches are retried."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "`empty`")
    ;; no page cache and no R process: nil, and nothing is pinned
    (should (null (ess-view-data--ensure-completion-cols)))
    (should (null ess-view-data-completion-candidate))
    ;; a second call retries instead of serving a cached nil
    (should (null (ess-view-data--ensure-completion-cols)))
    (should (null ess-view-data-completion-candidate))
    ;; column values follow the same rule
    (should (null (ess-view-data--column-values "x")))
    (should (null ess-view-data-completion-candidate))))

(ert-deftest ess-view-data-test-completion-wide-table ()
  "Wide tables cache all column names and keep per-column values separate."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "wide")
    (let ((cols (cl-loop for i from 0 below 200
                         collect (format "col-%d" i))))
      (setq-local ess-view-data--page-cols cols)
      (should (equal cols (ess-view-data--ensure-completion-cols)))
      ;; names are cached; the page cache is no longer needed
      (setq-local ess-view-data--page-cols nil)
      (should (equal cols (ess-view-data--ensure-completion-cols)))
      ;; per-column values stay independent across the full range
      (ess-view-data--completion-put
       (ess-view-data--completion-key 'column "col-0") '("a" "b"))
      (ess-view-data--completion-put
       (ess-view-data--completion-key 'column "col-199") '("x" "y" "z"))
      (should (equal '("a" "b") (ess-view-data--column-values "col-0")))
      (should (equal '("x" "y" "z") (ess-view-data--column-values "col-199")))
      ;; untouched columns still miss
      (should (null (ess-view-data--column-values "col-100"))))))

(ert-deftest ess-view-data-test-completion-name-collision ()
  "A column named like the object never clobbers the column-name entry."
  (with-temp-buffer
    (setq-local ess-view-data-temp-object "mtcars")
    (setq-local ess-view-data--page-cols '("mtcars" "mpg"))
    (should (equal '("mtcars" "mpg") (ess-view-data--ensure-completion-cols)))
    ;; values for the colliding column land in the column namespace
    (ess-view-data--completion-put
     (ess-view-data--completion-key 'column "mtcars") '("6" "8"))
    (should (equal '("mtcars" "mpg") (ess-view-data--ensure-completion-cols)))
    (should (equal '("6" "8") (ess-view-data--column-values "mtcars")))
    ;; backtick-quoted variants hit the same normalized keys
    (should (equal '("mtcars" "mpg")
                   (ess-view-data--ensure-completion-cols "`mtcars`")))
    (ess-view-data--completion-put
     (ess-view-data--completion-key 'column "my col") '("1" "2"))
    (should (equal '("1" "2") (ess-view-data--column-values "`my col`")))))

(ert-deftest ess-view-data-test-table-entries-format ()
  "`--table-entries' yields (ID VECTOR) pairs, not dotted pairs.
`tabulated-list-print' reads `(cadr entry)' as the column vector, so a
dotted pair would make it take the first cell instead and signal
`wrong-type-argument listp' on the vector."
  (with-temp-buffer
    (let ((entries (ess-view-data--table-entries
                    '(("a1" "1" "c1") ("a2" "2" "c2"))
                    '(10 10 10))))
      (should (= 2 (length entries)))
      (dolist (e entries)
        (should (equal 2 (length e)))
        (should (listp e))
        (should (vectorp (nth 1 e)))))))

(ert-deftest ess-view-data-test-table-print-runs ()
  "`--table-print' renders a protocol page without signaling (regression).
Covers the full parse -> entries -> `tabulated-list-print' chain that
previously failed with `wrong-type-argument listp' on dotted pairs."
  (let* ((proto (concat "EVD_N 2\n"
                        "EVD_ROWS r1\tr2\n"
                        "EVD_COLS a\tb\tc\n"
                        "EVD_TYPES chr\tint\tchr\n"
                        "a1\t1\tc1\n"
                        "a2\t2\tc2\n"
                        ""))
         (data (ess-view-data--page-data proto)))
    (should data)
    (with-temp-buffer
      (let ((ess-view-data-rows-per-page 200)
            (ess-view-data-page-number 0)
            (ess-view-data--sort-state nil))
        (ess-view-data--table-print data))
      (should (equal 2 (length tabulated-list-entries)))
      (dolist (e tabulated-list-entries)
        (should (vectorp (nth 1 e)))))))

(ert-deftest ess-view-data-test-table-mixed-types ()
  "A page mixing factor/date/logical/numeric/char renders without error.
Header labels keep the protocol type suffix and only numeric columns
are flagged right-aligned."
  (let* ((proto (concat "EVD_N 3\n"
                        "EVD_ROWS r1\tr2\tr3\n"
                        "EVD_COLS fac\tdt\tlgl\tnum\tchr\n"
                        "EVD_TYPES fct\tdate\tlgl\tdbl\tchr\n"
                        "high\t2024-01-15\tTRUE\t3.14\thello\n"
                        "low\t2024-02-20\tFALSE\t2.718\tworld\n"
                        "medium\t2024-03-25\tTRUE\t1.618\tfoo\n"
                        ""))
         (data (ess-view-data--page-data proto)))
    (should (equal 3 (nth 0 data)))
    (should (equal '("fac" "dt" "lgl" "num" "chr") (nth 2 data)))
    (should (equal '("fct" "date" "lgl" "dbl" "chr") (nth 3 data)))
    (with-temp-buffer
      (let ((ess-view-data-rows-per-page 200)
            (ess-view-data-page-number 0)
            (ess-view-data--sort-state nil))
        (ess-view-data--table-print data))
      (should (= 3 (length tabulated-list-entries)))
      (dolist (e tabulated-list-entries)
        (should (vectorp (nth 1 e)))
        (should (= 5 (length (nth 1 e)))))
      ;; header labels carry the type suffix
      (should (equal "fac [fct]" (car (aref tabulated-list-format 0))))
      (should (equal "dt [date]" (car (aref tabulated-list-format 1))))
      (should (equal "lgl [lgl]" (car (aref tabulated-list-format 2))))
      (should (equal "num [dbl]" (car (aref tabulated-list-format 3))))
      (should (equal "chr [chr]" (car (aref tabulated-list-format 4))))
      ;; only numeric columns are right aligned
      (should (null (plist-get (nthcdr 3 (aref tabulated-list-format 0)) :right-align)))
      (should (null (plist-get (nthcdr 3 (aref tabulated-list-format 1)) :right-align)))
      (should (null (plist-get (nthcdr 3 (aref tabulated-list-format 2)) :right-align)))
      (should (plist-get (nthcdr 3 (aref tabulated-list-format 3)) :right-align))
      (should (null (plist-get (nthcdr 3 (aref tabulated-list-format 4)) :right-align))))))

(ert-deftest ess-view-data-test-table-empty-data ()
  "Empty pages hit the no-data branch with a well-formed single entry."
  (let* ((proto (concat "EVD_N 0\n"
                        "EVD_ROWS\n"
                        "EVD_COLS\n"
                        "EVD_TYPES\n"
                        ""))
         (data (ess-view-data--page-data proto)))
    (should (equal 0 (nth 0 data)))
    (should (null (nth 2 data)))
    (with-temp-buffer
      (let ((ess-view-data-rows-per-page 200)
            (ess-view-data-page-number 0)
            (ess-view-data--sort-state nil))
        (ess-view-data--table-print data))
      (should (equal "No data" (car (aref tabulated-list-format 0))))
      (should (= 1 (length tabulated-list-entries)))
      (should (listp (car tabulated-list-entries)))
      (should (vectorp (nth 1 (car tabulated-list-entries)))))))

(ert-deftest ess-view-data-test-table-error-branch ()
  "The protocol-failure branch renders (ID VECTOR) entries."
  (with-temp-buffer
    (ess-view-data--table-error "Error: boom\nsecond line")
    (should (= 2 (length tabulated-list-entries)))
    (dolist (e tabulated-list-entries)
      (should (listp e))
      (should (vectorp (nth 1 e))))))

(defun ess-view-data-test--mock-proc ()
  "A live process object with a nil `busy' property, for render tests.
`ess-view-data--table-render-page' requires a process that is not busy
before it will query R; this fake lets the Emacs-side render chain run
in a batch session where `ess-string-command' is stubbed."
  (make-process :name "ess-view-data-test-proc"
                :command (if (eq system-type 'windows-nt)
                             (list "cmd.exe" "/c" "exit")
                           (list "/bin/sh" "-c" "exit"))))

(ert-deftest ess-view-data-test-integration-empty-df ()
  "Smoke: a rendered empty data frame lands in the no-data branch.
Runs the full render chain (protocol output -> parse -> branch) with
the R round-trip stubbed."
  (let ((proc (ess-view-data-test--mock-proc)))
    (unwind-protect
        (cl-letf (((symbol-function 'get-process) (lambda (_) proc))
                  ((symbol-function 'ess-string-command)
                   (lambda (_cmd) "EVD_N 0\nEVD_ROWS\nEVD_COLS\nEVD_TYPES\n"))
                  ((symbol-function 'ess-view-data--ensure-protocol)
                   (lambda (_proc) nil)))
          (with-temp-buffer
            (setq-local ess-local-process-name "R")
            (ess-view-data--table-render-page (current-buffer))
            (should (equal "No data" (car (aref tabulated-list-format 0))))
            (should (= 1 (length tabulated-list-entries)))
            (should (listp (car tabulated-list-entries)))
            (should (vectorp (nth 1 (car tabulated-list-entries))))))
      (kill-process proc))))

(ert-deftest ess-view-data-test-integration-protocol-error ()
  "Smoke: a protocol failure text renders the Error branch.
Runs the full render chain; the R output lacks the EVD_N header, so
parsing fails and the failure text is displayed."
  (let ((proc (ess-view-data-test--mock-proc)))
    (unwind-protect
        (cl-letf (((symbol-function 'get-process) (lambda (_) proc))
                  ((symbol-function 'ess-string-command)
                   (lambda (_cmd) "Error: object 'ae' not found\nExecution halted\n"))
                  ((symbol-function 'ess-view-data--ensure-protocol)
                   (lambda (_proc) nil)))
          (with-temp-buffer
            (setq-local ess-local-process-name "R")
            (ess-view-data--table-render-page (current-buffer))
            (should (equal "Error" (car (aref tabulated-list-format 0))))
            (should (= 2 (length tabulated-list-entries)))
            (dolist (e tabulated-list-entries)
              (should (vectorp (nth 1 e))))))
      (kill-process proc))))

(provide 'ess-view-data-test)
;;; ess-view-data-test.el ends here
