;;; ess-view-data.el --- View Data                   -*- lexical-binding: t; -*-

;; Copyright (C) 2019-2023  Shuguang Sun <shuguang79@qq.com>

;; Author: Shuguang Sun <shuguang79@qq.com>
;; Created: 2019/04/06
;; Version: 1.3
;; URL: https://github.com/ShuguangSun/ess-view-data
;; Package-Requires: ((emacs "26.1") (ess "18.10.1"))
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Customization:
;; ess-view-data-backend-list: dplyr (default), dplyr+DT, data.table+magrittr
;; ess-view-data-print-backend-list: print (default), kable
;; ess-view-data-save-backend-list: write.csv (default), readr::write_csv,
;;                                  data.table::fwrite kable
;; ess-view-data-complete-backend-list: jsonlite
;; ess-view-data-read-string: ess-completing-read (default), completing-read,
;;                            ido-completing-read, ivy-completing-read
;; ess-view-data-display-backend: how to display data in the view buffer.
;;   `table' (default): a structured tabulated-list with column types, aligned
;;   cells, truncated long cells and clickable sort headers.
;;   `print' / `kable': keep the historical text output of the print/kable
;;   backends (csv text with the '# Trace' / '# Last' / '# Page number' head
;;   lines and a csv-mode column header).
;;   To restore the historical csv + header view, set
;;   `ess-view-data-display-backend' to `print', e.g.:
;;
;;     M-x customize-option RET ess-view-data-display-backend RET print
;;     (setq ess-view-data-display-backend 'print)
;;
;;   NB: the setting is global; refresh the current view buffer
;;   (ess-view-data-reset or re-run ess-view-data-print) after switching.
;;
;; Table display keys (`ess-view-data-table-mode'):
;;   S: sort by the column at point (server-side arrange over the whole data).
;;   W: widen the current column; cells re-truncate from the full-value cache
;;      at the new width, so repeated W reveals more of every long cell.
;;   w: ess-view-data-widen-current-column-full - fit the current column to
;;      its longest full value.
;;   a: ess-view-data-widen-all-columns-full - fit every column to its longest
;;      full value; the whole current page then sits in the buffer as full
;;      text and built-in isearch (C-s / C-r) can search the full values.
;;   v: ess-view-data-show-cell-value - show the full cell value at point in a
;;      read-only buffer (from the local cache, no R round trip).

;; Utils:
;; NOTE: it will make a copy of the data and then does the following action
;; ess-view-data-print: the main function to view data

;; Example: In a ess-r buffer or a Rscript buffer, `M-x ess-view-data-print`
;; and input `mtcars`.

;; ess-view-data-set-backend: change backend
;; ess-view-data-toggle-maxprint: toggle limitation of lines per page to print

;; ess-view-data-verbs

;; Example: In the ESS-V buffer, `M-x ess-view-data-verbs` and select the verb
;; to do with.

;; ess-view-data-filter

;; Example: In the ESS-V buffer, `M-x ess-view-data-filter`, `cyl <RET> mpg` to
;; select columns and <C-j> to finish input.  An indirect buffer pops up and
;; 'data-masking' Expressions can be edited.

;; ess-view-data-select / ess-view-data-unselect

;; Example: In the ESS-V buffer, `M-x ess-view-data-select`, `cyl <RET> mpg` to
;; select columns and <C-j> to finish input.

;; ess-view-data-sort
;; ess-view-data-group / ess-view-data-ungroup
;; ess-view-data-mutate
;; ess-view-data-slice
;; ess-view-data-wide2long / ess-view-data-long2wide
;; ess-view-data-update
;; ess-view-data-reset

;; Example: In the ESS-V buffer, `M-x ess-view-data-reset`, an indirect buffer
;; pops up and the action history can be edited.

;; ess-view-data-unique
;; ess-view-data-count

;; Example: In the ESS-V buffer, `M-x ess-view-data-count`, `cyl <RET> mpg` to
;; select columns and <C-j> to finish input.  In the updated buffer with count
;; information, `M-x ess-view-data-print` to go back.

;; ess-view-data-summarise
;; ess-view-data-overview
;; ess-view-data-goto-page / -next-page / -previous-page / -first-page /
;;                           -last-page / -page-number
;; ess-view-data-save

;;; Code:

(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'cl-generic))

(require 'cl-lib)
(require 'ess-inf)
(require 'ess-rdired)
(require 'ess-r-mode)
(require 'ess-r-completion)
(require 'subr-x)
(require 'json)
(require 'tabulated-list)

(defgroup ess-view-data ()
  "View data: ess-view-data."
  :group 'ess
  :prefix "ess-view-data-")

(defcustom ess-view-data-buffer-name-format "*R Data View: %1$s (%2$s)*"
  "Buffer name for R data, with two parameter: variable name, proc-name."
  :type 'string
  :group 'ess-view-data)

(defcustom ess-view-data-source-buffer-name-format "*R Data View Edit: %s*"
  "Buffer for R data."
  :type 'string
  :group 'ess-view-data)

;; FIXME: r symbol name
(defcustom ess-view-data-objname-regex "^[^a-zA-Z]\\|[^.a-zA-Z0-9]+"
  "Object name needs to be back quoted."
  :type 'string
  :group 'ess-view-data)

(defcustom ess-view-data-options-width 5000
  "Width to print data: options(width= `ess-view-data-options-width')."
  :type 'integer
  :group 'ess-view-data)

(defcustom ess-view-data-rows-per-page 200
  "Rows per page."
  :type 'integer
  :group 'ess-view-data)

(defcustom ess-view-data-show-code t
  "Show code on top of the view data buffer."
  :type 'boolean
  :group 'ess-view-data)

(defcustom ess-view-data-show-no-page-number t
  "Not to show page number on top of the view data buffer."
  :type 'boolean
  :group 'ess-view-data)

(defcustom ess-view-data-write-dribble t
  "Write to dribble for tracking."
  :type 'boolean
  :group 'ess-view-data)

(defcustom ess-view-data-tibble-crayon-enabled-p nil
  "Whether to enable crayon for tibble.

If enabled, `ansi-color-for-comint-mode-on' should be turn on."
  :type 'boolean
  :group 'ess-view-data)


(defvar ess-view-data-backend-list
  (list 'dplyr 'dplyr+DT 'data.table+magrittr)
  "List of backends.")

(defcustom ess-view-data-current-backend 'dplyr
  "The ess-view-data backend in using."
  :type `(choice ,@(mapcar (lambda (x)
			                 `(const :tag ,(symbol-name x) ,x))
			               ess-view-data-backend-list)
                 (symbol :tag "Other"))
  :group 'ess-view-data)


(defvar ess-view-data-print-backend-list
  (list 'print 'kable)
  "List of backends.")


(defcustom ess-view-data-current-update-print-backend 'print
  "The ess-view-data backend in using."
  :type `(choice ,@(mapcar (lambda (x)
			                 `(const :tag ,(symbol-name x) ,x))
			               ess-view-data-print-backend-list)
                 (symbol :tag "Other"))
  :group 'ess-view-data)

(defcustom ess-view-data-current-summarise-print-backend 'kable
  "The ess-view-data backend in using."
  :type `(choice ,@(mapcar (lambda (x)
			                 `(const :tag ,(symbol-name x) ,x))
			               ess-view-data-print-backend-list)
                 (symbol :tag "Other"))
  :group 'ess-view-data)


(defcustom ess-view-data-display-backend 'table
  "How to display data in the view buffer.

`table' renders a structured tabulated list with column types,
aligned cells and clickable sort headers.  `print' and `kable'
keep the historical text output of `ess-view-data-current-update-
print-backend' / `ess-view-data-current-summarise-print-backend'."
  :type '(choice (const :tag "table" table)
                 (const :tag "print" print)
                 (const :tag "kable" kable))
  :group 'ess-view-data)

(defcustom ess-view-data-column-width-cap 16
  "Maximum width of a table column cell before truncation."
  :type 'integer
  :group 'ess-view-data)


(defvar ess-view-data-save-backend-list
  (list 'write.csv 'readr::write_csv 'data.table::fwrite 'kable)
  "List of backends for write data to csv.")

(defcustom ess-view-data-current-save-backend 'write.csv
  "The backend to save data."
  :type `(choice ,@(mapcar (lambda (x)
			                 `(const :tag ,(symbol-name x) ,x))
			               ess-view-data-save-backend-list)
                 (symbol :tag "Other"))
  :group 'ess-view-data)

(defvar ess-view-data-complete-backend-list
  (list 'jsonlite)
  "List of backends to read completion list.")

(defcustom ess-view-data-current-complete-backend 'jsonlite
  "The backend to save data."
  :type `(choice ,@(mapcar (lambda (x)
			                 `(const :tag ,(symbol-name x) ,x))
			               ess-view-data-complete-backend-list)
                 (symbol :tag "Other"))
  :group 'ess-view-data)


(defcustom ess-view-data-read-string 'ess-completing-read
  "The function used to completing read."
  :type `(choice (const :tag "ESS" ess-completing-read)
                 (const :tag "basic" completing-read)
                 (const :tag "ido" ido-completing-read)
                 (const :tag "ivy" ivy-completing-read)
                 (function :tag "Other"))
  :group 'ess-view-data)


;; TODO: configure input functions here
(defvar ess-view-data-backend-setting
  '((dplyr . (:desc "desc(%s)" :slice "pos, like 1, 1:5, n(): "))
    (dplyr+DT . (:desc "desc(%s)" :slice "pos, like 1, 1:5, n(): "))
    (data.table+magrittr . (:desc "-%s" :slice "pos, like 1, 1:5, .N: ")))
  "List of backends.")

(defvar ess-view-data-verb-update-list
  (list "select" "unselect" "sort" "group" "ungroup" "slice")
  "List of verbs which can change the data.")

(defvar ess-view-data-verb-update-indirect-list
  (list "filter" "mutate" "transmute"
        "wide2long" "long2wide" "wide2long-pivot_longer" "long2wide-pivot_wider")
  "List of verbs which can change the data.")

(defvar ess-view-data-verb-summarise-list
  (list "count" "unique" "slice" "summarise" "skimr" "skimr-all")
  "List of verbs which do summarise.")

(defvar ess-view-data-verb-summarise-indirect-list
  (list "count" "unique" "slice" "summarise")
  "List of verbs which do summarise.")

(defvar-local ess-view-data-object nil
  "Cache of object name.")

(defvar-local ess-view-data-temp-object nil
  "Temporary variable for ess-view-data.")

(defvar ess-view-data-temp-object-list '()
  "List of temporary variable for ess-view-data.")

(defvar-local ess-view-data-maxprint-p nil
  "Whether to print all data in one page.")

(defvar-local ess-view-data-page-number 0
  "Current page number - 1.")

(defvar-local ess-view-data-total-page 1
  "Total page number.")


(defvar-local ess-view-data-history nil
  "The history of operations.")

(defvar-local ess-view-data-completion-object nil
  "The candidate for completion.")

(defvar-local ess-view-data-completion-candidate nil
  "The candidate for completion.")




(defvar ess-view-data-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap (kbd "C-c C-p") #'ess-view-data-print-ex)
    (define-key keymap (kbd "C-c C-t") #'ess-view-data-toggle-maxprint)
    (define-key keymap (kbd "C-c C-s") #'ess-view-data-select)
    (define-key keymap (kbd "C-c C-u") #'ess-view-data-unselect)
    (define-key keymap (kbd "C-c C-f") #'ess-view-data-filter)
    (define-key keymap (kbd "C-c C-o") #'ess-view-data-sort)
    ;; (define-key keymap (kbd "C-c C-g") #'ess-view-data-group)
    ;; (define-key keymap (kbd "C-c C-G") #'ess-view-data-ungroup)
    (define-key keymap (kbd "C-c C-i") #'ess-view-data-slice)
    (define-key keymap (kbd "C-c C-l") #'ess-view-data-unique)
    (define-key keymap (kbd "C-c C-v") #'ess-view-data-summarise)
    (define-key keymap (kbd "C-c C-r") #'ess-view-data-reset)
    (define-key keymap (kbd "C-c C-w") #'ess-view-data-save)
    (define-key keymap (kbd "C-c C-t") #'ess-view-data-show-history)
    (define-key keymap (kbd "M-g p") #'ess-view-data-goto-previous-page)
    (define-key keymap (kbd "M-g n") #'ess-view-data-goto-next-page)
    (define-key keymap (kbd "M-g f") #'ess-view-data-goto-first-page)
    (define-key keymap (kbd "M-g l") #'ess-view-data-goto-last-page)
    keymap)
  "Keymap for function `ess-view-data-mode'.")

;;; Indirect Buffers Minor Mode
(defvar ess-view-data-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c'" #'ess-view-data-do-commit)
    (define-key map "\C-c\C-k" #'ess-view-data-commit-abort)
    (define-key map "\C-c\C-i" #'ess-view-data-complete-object)
    (define-key map "\C-c\C-l" #'ess-view-data-complete-data)
    (define-key map "\C-c\C-a" #'ess-view-data-insert-all-cols)
    (define-key map "\C-c\C-v" #'ess-view-data-insert-all-values)
    map)
  "Keymap for `ess-view-data-edit-mode', a minor mode.")

(defvar ess-view-data-edit-mode-hook nil
  "Hook for the `ess-view-data-edit-mode' minor mode.")

(define-minor-mode ess-view-data-edit-mode
  "Minor mode for special key bindings in a ess-view-data-edit buffer.

Turning on this mode runs the normal hook `ess-view-data-edit-mode-hook'."
  :lighter " Evd"
  (setq-local
   header-line-format
   (substitute-command-keys
    "Edit, then exit with `\\[ess-view-data-do-commit] '' or abort with `\\[ess-view-data-commit-abort]'")))

;;; Utils

;;; Page math

(defun ess-view-data--page-total (nrow rows-per-page)
  "Total page count for an object with NROW rows at ROWS-PER-PAGE rows each.
Always returns at least 1 so that empty data still shows one (empty) page."
  (max 1 (ceiling nrow rows-per-page)))

(defun ess-view-data--page-slice (page-number rows-per-page nrow)
  "R slice string for PAGE-NUMBER (0-based) of an object with NROW rows.
Return nil when the page is empty (NROW is 0 or PAGE-NUMBER is out of range).
Argument ROWS-PER-PAGE page number."
  (let ((start (1+ (* page-number rows-per-page)))
        (end (min (* (1+ page-number) rows-per-page) nrow)))
    (when (and (> nrow 0) (<= start end))
      (format "[%d:%d,]" start end))))

(defun ess-view-data--page-slice-expr (page-number rows-per-page obj)
  "Guarded R slice expression for PAGE-NUMBER (0-based) of OBJ.
Used by the text render path where NROW is not known in Emacs.
Evaluates to `integer(0)' when OBJ is empty, otherwise to the page slice.
Argument ROWS-PER-PAGE rows per page."
  (format "[if (nrow(%1$s) < 1) integer(0) else (%2$d*%3$d + 1):min((%2$d + 1)*%3$d, nrow(%1$s)),]"
          obj page-number rows-per-page))

(defun ess-view-data--r-quote-string (str)
  "Return STR as a valid R string literal.
Backslashes are converted to forward slashes and double quotes are
escaped, so that Windows paths produce valid R code."
  (concat "\""
          (replace-regexp-in-string
           "\"" "\\\\\""
           (replace-regexp-in-string "\\\\" "/" str))
          "\""))

(defun ess-view-data--run-r (cmd &optional buf no-prompt-check wait proc)
  "Send CMD to the ESS process and return non-nil when it was sent.
PROC defaults to the process from `ess-local-process-name'.  When the
process is busy, signal a `user-error' with a clear message instead of
silently dropping CMD, so that callers can preserve their state.
Optional argument BUF is the buffer to send from; NO-PROMPT-CHECK
skips the busy check; WAIT is passed through to the process call."
  (let ((proc (or proc (get-process ess-local-process-name))))
    (cond
     ((null proc)
      (user-error "No ESS process to run the command"))
     ((process-get proc 'busy)
      (user-error "R process %s is busy; wait for it to finish and retry"
                  (process-name proc)))
     (t
      (ess-command cmd buf no-prompt-check wait nil proc)
      t))))

;;; Backend Access API

(cl-defgeneric ess-view-data--do-print (_backend)
  "Benchmark function to do print.

Argument BACKEND Backend to dispatch, i.e.,
the `ess-view-data-current-update-print-backend'.")

(cl-defgeneric ess-view-data--do-update (_backend fun action)
  "Do Update.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument FUN Action verb, e.g., select, filter, count.
Argument ACTION Parameter (R script) for FUN.")

(cl-defgeneric ess-view-data--do-summarise (_backend fun action)
  "Do summarising.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument FUN Action verb, e.g., count, unique, skimr.
Argument ACTION Parameter (R script) for FUN.")

(cl-defgeneric ess-view-data--do-reset (_backend action)
  "Reset print buffer.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument ACTION R script to reset the view process.")

(cl-defgeneric ess-view-data-do-save (_backend file-name)
  "Save.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument FILE-NAME File name to save to.")

(cl-defgeneric ess-view-data-do-complete-data (_backend &optional dataframe)
  "Completing input.

Argument BACKEND Backend to dispatch, i.e.,
the `ess-view-data-current-complete-backend'.
Optional argument DATAFRAME Data frame to complete.")

(cl-defgeneric ess-view-data-get-total-page (_backend proc-name proc)
  "Total number of pages.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Argument PROC The associated ESS process.")

(cl-defgeneric ess-view-data--header-line (_backend)
  "Head-line.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.")

(cl-defgeneric ess-view-data--initialize-backend (_backend _proc-name _proc)
  "Initialization.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Argument PROC The associated ESS process."
  nil)

(cl-defgeneric ess-view-data-do-kill-buffer-hook (_backend _proc-name _proc)
  "Functions to run after `kill-buffer' on '*R Data View' buffer.

Argument BACKEND Backend to dispatch, i.e., the `ess-view-data-current-backend'.
Argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Argument PROC The associated ESS process.")

;;; * Shared backend skeleton (Phase 2, dedup)

;;; ** Verb table: data-driven code generation

(defvar ess-view-data--verb-table
  (let ((dplyr-verbs
         '((select   . (cols . " %>% dplyr::select(%s)"))
           (unselect . (cols-neg . " %>% dplyr::select(%s)"))
           (filter   . (raw . " %>% dplyr::filter(%s)"))
           (mutate   . (raw . " %>% dplyr::mutate(%s)"))
           (sort     . (cols . " %>% dplyr::arrange(%s, .by_group = TRUE)"))
           (group    . (cols . " %>% dplyr::group_by(%s)"))
           (ungroup  . (cols . " %>% dplyr::ungroup(%s)"))
           (slice    . (raw . " %>% dplyr::slice(%s)"))
           (transmute . (raw . " %>% dplyr::transmute(%s)"))
           (wide2long . (raw . " %>% tidyr::gather(%s)"))
           (long2wide . (raw . " %>% tidyr::spread(%s)"))
           (wide2long-pivot_longer . (raw . " %>% tidyr::pivot_longer(%s)"))
           (long2wide-pivot_wider  . (raw . " %>% tidyr::pivot_wider(%s)"))
           (count  . (cols . " %>% dplyr::count(%s)"))
           (unique . (cols . " %>% dplyr::distinct(%s)"))
           (skimr  . (cols . " %>% skimr::skim(%s)"))
           (skimr-all . (fixed . " %>% skimr::skim()"))
           (summarise . (raw . " %>% %s"))
           (update . (raw . " %>% %s")))))
    (list (cons 'dplyr dplyr-verbs)
          (cons 'dplyr+DT dplyr-verbs)
          (cons 'data.table+magrittr
                '((select . (cols . " %>% .[, .(%s)]"))
                  (unselect . (cols-null . " %>% .[,`:=`(%s)]"))
                  (filter . (raw . " %>% .[%s,]"))
                  (mutate . (raw . " %>% .[,`:=`(%s)]"))
                  (sort . (cols . " %>% setorder(., %s)"))
                  (group . (state . ess-view-data--group))
                  (ungroup . (error . "No single ungroup step for data.table+magrittr"))
                  (slice . (builder . ess-view-data--dt-slice))
                  (transmute . (raw . " %>% .[,`:=`(%s)]"))
                  (wide2long . (raw . " %>% melt(., %s)"))
                  (long2wide . (raw . " %>% dcast(., %s)"))
                  (count . (cols . " %>% .[, .N, by = .(%s)] "))
                  (unique . (builder . ess-view-data--dt-unique))
                  (skimr . (cols . " %>% skimr::skim(%s)"))
                  (skimr-all . (fixed . " %>% skimr::skim()"))
                  (summarise . (raw . " %>% %s"))
                  (update . (raw . " %>% %s"))))))
  "Verb code generation table, indexed by backend then verb.

Each entry maps VERB to (KIND . PAYLOAD):
- (cols . FMT): ACTION is a list of columns, de-duplicated, reversed and
  joined with \",\" before formatting into FMT (e.g. dplyr::select).
- (cols-neg . FMT): like cols, but every column is prefixed with \"-\"
  (dplyr unselect).
- (cols-null . FMT): like cols, but every column is suffixed with
  \" = NULL\" (data.table unselect).
- (raw . FMT): ACTION is an R expression string inserted verbatim
  (filter, mutate, slice, wide2long, ...); a list is joined with \",\".
- (fixed . STR): the snippet is STR regardless of ACTION (skimr-all).
- (state . VAR): store the joined column list in buffer-local VAR and
  produce no snippet (data.table group).
- (builder . FN): FN is called with ACTION and returns the snippet,
  used when the verb needs surrounding state (data.table slice) or a
  custom column transform (data.table unique).
- (error . MSG): signal MSG (data.table ungroup).

Snippets start with \" %>% \" exactly like the pcase branches they
replace, so generated history strings stay byte-identical.")

(defun ess-view-data--join-cols (cols &optional prefix suffix)
  "Join COLS with \",\" after de-duplication and reversal.

PREFIX is prepended and SUFFIX appended to each column."
  (mapconcat (lambda (x) (concat (or prefix "") x (or suffix "")))
             (delete-dups (nreverse cols)) ","))

(defun ess-view-data--verb-format (fmt &rest args)
  "Format FMT with ARGS, treating literal percent signs as literals.

Only \"%s\" placeholders are substituted; other \"%\" characters
\(e.g. in \" %>% \") are escaped for `format'."
  (apply #'format
         (replace-regexp-in-string "%\\([^s%]\\)" "%%\\1" fmt)
         args))

(defvar-local ess-view-data--group nil
  "Group columns of the data.table+magrittr backend, set by `group'.")

(defvar-local ess-view-data--parent-buffer nil
  "Parent view buffer of the current edit-indirect buffer.")
(defvar-local ess-view-data--reset-buffer-p nil
  "Non-nil when the current edit buffer is the reset buffer.")
(defvar-local ess-view-data--action nil
  "Action plist of the current edit buffer.")

(defvar-local ess-view-data--render-object nil
  "R expression rendered for the current page, or nil for the temp object.
Set by the summarise verbs so that their result is displayed without
changing the temp object; see `ess-view-data--render'.")
(defvar-local ess-view-data--last-command nil
  "History snippet of the last action, for `ess-view-data-show-history'.")
(defvar-local ess-view-data--sort-state nil
  "Current server-side sort as (COL-NAME . DESC-P), or nil.")
(defvar-local ess-view-data--page-cols nil
  "Column names of the current page (table display protocol cache).")
(defvar-local ess-view-data--table-rows nil
  "Full cell rows of the current page (table display protocol cache).
Set together with `ess-view-data--page-cols' by `ess-view-data--table-print'.")
(defvar-local ess-view-data--table-types nil
  "Protocol column types of the current page (table display protocol cache).")

(defun ess-view-data--display-table-p ()
  "Non-nil when the table display backend is active."
  (eq ess-view-data-display-backend 'table))

(defun ess-view-data--render-object-or-temp ()
  "R expression to render: `ess-view-data--render-object' or the temp object."
  (or ess-view-data--render-object ess-view-data-temp-object))

(defun ess-view-data--dt-slice (action)
  "Build the data.table slice snippet for ACTION.

The slice needs the group columns set by the previous `group' verb,
stored in `ess-view-data--group'."
  (if ess-view-data--group
      (ess-view-data--verb-format " %>% .[, .SD[%s], by = .(%s)]"
                                  action ess-view-data--group)
    (error "Group is required for data.table+magrittr")))

(defun ess-view-data--dt-unique (action)
  "Build the data.table unique snippet for ACTION.

Backquoted column names are unwrapped and quoted with double quotes."
  (ess-view-data--verb-format
   " %>% unique(., by = c(\"%s\"))"
   (mapconcat (lambda (x)
                (replace-regexp-in-string "^`\\(.*\\)`$" "\\1" x))
              (delete-dups (nreverse action)) "\",\"")))

(defun ess-view-data--verb-code (backend fun action)
  "Return the R pipeline snippet for FUN of BACKEND applied to ACTION.

Unknown verbs fall back to \" %>% ACTION\", the historical default."
  (let* ((entry (alist-get fun (alist-get backend ess-view-data--verb-table)))
         (kind (car entry))
         (payload (cdr entry)))
    (pcase kind
      ('cols (ess-view-data--verb-format payload (ess-view-data--join-cols action)))
      ('cols-neg (ess-view-data--verb-format payload (ess-view-data--join-cols action "-")))
      ('cols-null (ess-view-data--verb-format payload (ess-view-data--join-cols action nil " = NULL")))
      ('raw (ess-view-data--verb-format payload (if (stringp action) action
                                                  (mapconcat #'identity action ","))))
      ('fixed payload)
      ('state (set payload (ess-view-data--join-cols action)) nil)
      ('builder (funcall payload action))
      ('error (error "%s" payload))
      (_ (ess-view-data--verb-format " %>% %s" (if (stringp action) action
                                                  (mapconcat #'identity action ",")))))))

;;; ** Shared command builders

(defun ess-view-data--render-page ()
  "Return the R expression rendering the current page of the temp object."
  (concat
   "local({"
   (format (ess-view-data--do-print ess-view-data-current-update-print-backend)
           (concat ess-view-data-temp-object
                   (unless ess-view-data-maxprint-p
                     (ess-view-data--page-slice-expr
                      ess-view-data-page-number
                      ess-view-data-rows-per-page
                      ess-view-data-temp-object)))
           ess-view-data-temp-object)
   "})\n"))

(defun ess-view-data--update-cmd (cmdhist)
  "Build the update command assigning CMDHIST.

In table display mode only the assignment is returned; the page is
rendered separately by `ess-view-data--render'.  In text mode the
page-rendering expression is appended as before."
  (concat ess-view-data-temp-object " <<- " ess-view-data-temp-object cmdhist "; "
          (unless (ess-view-data--display-table-p)
            (ess-view-data--render-page))))

(defun ess-view-data--reset-cmd (cmdhist)
  "Build the reset command assigning CMDHIST.

In table display mode only the assignment is returned; the page is
rendered separately by `ess-view-data--render'.  In text mode the
page-rendering expression is appended as before."
  (concat ess-view-data-temp-object " <<- " cmdhist "; "
          (unless (ess-view-data--display-table-p)
            (ess-view-data--render-page))))

(defun ess-view-data--summarise-cmd (cmdhist)
  "Build the summarise command rendering `temp CMDHIST' without assigning."
  (concat
   "local({"
   (format (ess-view-data--do-print ess-view-data-current-summarise-print-backend)
           (concat ess-view-data-temp-object cmdhist)
           ess-view-data-temp-object)
   "})\n"))

(defun ess-view-data--page-number (page &optional pnumber)
  "Return the 0-based page number for navigation symbol PAGE.

PAGE is one of `first', `last', `previous', `next', `page' (with
PNUMBER) or any other symbol, meaning keep the current page."
  (pcase page
    ('first 0)
    ('last (max 0 (1- ess-view-data-total-page)))
    ('previous (max 0 (1- ess-view-data-page-number)))
    ('next (min (1+ ess-view-data-page-number) (max 0 (1- ess-view-data-total-page))))
    ('page (max (min pnumber (max 0 (1- ess-view-data-total-page))) 0))
    (_ ess-view-data-page-number)))

(defun ess-view-data--get-total-page (rpp proc-name proc)
  "Update `ess-view-data-total-page' from R, counting RPP rows per page.
Argument PROC-NAME names the ESS process; PROC is the process object."
  (when (and proc-name proc
             (not (process-get proc 'busy)))
    (setq ess-view-data-total-page
          (ess-view-data--page-total
           (string-to-number
            (car (ess-get-words-from-vector
                  (format "as.character(nrow(%s))\n" ess-view-data-temp-object))))
           rpp))))

(defun ess-view-data--rm-temp-object (proc-name proc)
  "Remove the temp object from R unless PROC is busy.
Argument PROC-NAME proc name."
  (when (and proc-name proc
             (not (process-get proc 'busy)))
    (ess-command (format "rm(%s, envir = globalenv())\n" ess-view-data-temp-object))
    (ess-write-to-dribble-buffer (format "[ESS-v] rm(%s, envir = globalenv())\n" ess-view-data-temp-object))))

;;; ** Page-data protocol (v1)

(defconst ess-view-data--protocol-r-code
  (concat
   "assign(\"ess_view_data_page\", value = function(expr, start = 1L, end = 200L) {\n"
   "  obj <- eval(substitute(expr), envir = .GlobalEnv)\n"
   "  n <- nrow(obj)\n"
   "  cat(\"EVD_N \", n, \"\\n\", sep = \"\")\n"
   "  if (n < 1L) {\n"
   "    cat(\"EVD_ROWS\\nEVD_COLS\\nEVD_TYPES\\n\")\n"
   "    return(invisible(NULL))\n"
   "  }\n"
   "  start <- max(1L, as.integer(start))\n"
   "  end <- min(n, as.integer(end))\n"
   "  x <- as.data.frame(obj[start:end, , drop = FALSE])\n"
   "  cat(\"EVD_ROWS \", paste(rownames(x), collapse = \"\\t\"), \"\\n\", sep = \"\")\n"
   "  cat(\"EVD_COLS \", paste(names(x), collapse = \"\\t\"), \"\\n\", sep = \"\")\n"
   "  cat(\"EVD_TYPES \", paste(vapply(x, function(z) {\n"
   "    if (is.factor(z)) {\n"
   "      \"fct\"\n"
   "    } else if (inherits(z, \"Date\")) {\n"
   "      \"date\"\n"
   "    } else if (inherits(z, \"POSIXt\")) {\n"
   "      \"dttm\"\n"
   "    } else if (is.logical(z)) {\n"
   "      \"lgl\"\n"
   "    } else if (is.integer(z)) {\n"
   "      \"int\"\n"
   "    } else if (is.numeric(z)) {\n"
   "      \"dbl\"\n"
   "    } else if (is.list(z)) {\n"
   "      \"lst\"\n"
   "    } else {\n"
   "      \"chr\"\n"
   "    }\n"
   "  }, character(1L)), collapse = \"\\t\"), \"\\n\", sep = \"\")\n"
   "  rows <- apply(x, 1L, function(v) {\n"
   "    v <- as.character(v)\n"
   "    v[is.na(v)] <- \"NA\"\n"
   "    paste(gsub(\"[\\t\\r\\n]\", \" \", v), collapse = \"\\t\")\n"
   "  })\n"
   "  cat(rows, sep = \"\\n\")\n"
   "  cat(\"\\n\")\n"
   "}, envir = .GlobalEnv)\n")
  "R source of the page-data protocol helper (protocol v1).
Sourced once per R session by `ess-view-data--ensure-protocol'.

The helper evaluates EXPR (passed unquoted) in .GlobalEnv, where the
backend init has attached dplyr/magrittr, prints an EVD_N header line
with the total row count and, when non-empty, EVD_ROWS/EVD_COLS/
EVD_TYPES lines plus TAB-separated data rows.  Cells have TAB and
newline replaced by space and missing values shown as NA.

The helper is installed with `assign' into .GlobalEnv, not with a
plain `<-': ESS wraps every `ess-command' in `local()' via
`ess-r-format-command', and a `<-' assignment inside `local()'
stays in the throw-away local environment, so the function would
never be visible to later queries.  Only `assign' with an explicit
ENVIR survives the wrapper.")

(defun ess-view-data--temp-exists-p (proc)
  "Return non-nil when the temp object exists in PROC's R session.
A busy process (or a missing PROC) is reported as having the object,
so initialization keeps the current state instead of racing with a
running command."
  (if (or (null proc) (process-get proc 'busy)
          (null ess-view-data-temp-object))
      t
    (string-match-p
     "TRUE"
     (ess-string-command
      (format "cat(exists(as.character(quote(%s)), envir = .GlobalEnv, inherits = FALSE), \"\\n\")\n"
              ess-view-data-temp-object)))))

(defun ess-view-data--ensure-protocol (proc)
  "Ensure the page-data protocol helper exists in PROC's R session.
Sends an idempotent R guard which (re)defines the helper only when it
is missing, so a restarted R session gets it back while a live one
pays a cheap `exists' check.  Callers may run this before every page
query."
  (when (and proc (not (process-get proc 'busy)))
    (ess-command
     (concat "if (!exists(\"ess_view_data_page\", mode = \"function\", envir = .GlobalEnv)) {\n"
             ess-view-data--protocol-r-code
             "}\n")
     nil nil nil nil proc)))

(defun ess-view-data--protocol-cmd ()
  "R expression querying the current page via the protocol."
  (format "ess_view_data_page(%s, %dL, %dL)\n"
          (ess-view-data--render-object-or-temp)
          (1+ (* ess-view-data-page-number ess-view-data-rows-per-page))
          (* (1+ ess-view-data-page-number) ess-view-data-rows-per-page)))

;;; ** Edit-indirect buffer templates

(defvar ess-view-data--template-table
  (let ((dplyr-templates
         '((header . "# Insert [all] variable name[s] (C-c C-i[a]), [all] Values (C-c C-l[v])\n")
           (default . "# %> ... \n")
           (filter . ess-view-data--tmpl-filter)
           (mutate . ess-view-data--tmpl-mutate)
           (wide2long . ess-view-data--tmpl-wide2long)
           (long2wide . ess-view-data--tmpl-long2wide)
           (wide2long-pivot_longer . ess-view-data--tmpl-pivot-longer)
           (long2wide-pivot_wider . ess-view-data--tmpl-pivot-wider)
           (summarise . ess-view-data--tmpl-summarise)
           (reset . ess-view-data--tmpl-reset))))
    (list (cons 'dplyr dplyr-templates)
          (cons 'dplyr+DT dplyr-templates)
          (cons 'data.table+magrittr
                '((header . "# Insert variable name[s] (C-c i[I]), Insert Values (C-c l[L])\n")
                  (default . "# ... \n")
                  (filter . ess-view-data--tmpl-dt-filter)
                  (mutate . ess-view-data--tmpl-dt-mutate)
                  (wide2long . ess-view-data--tmpl-dt-wide2long)
                  (long2wide . ess-view-data--tmpl-dt-long2wide)
                  (summarise . ess-view-data--tmpl-dt-summarise)
                  (reset . ess-view-data--tmpl-reset)))))
  "Edit-indirect buffer templates, indexed by backend.

Each backend entry holds the header comment lines plus one template
function per verb.  Verbs without an entry use the default template.")

(defun ess-view-data--tmpl-filter (obj-list)
  "Insert the dplyr filter edit template for OBJ-LIST."
  (setq ess-view-data-completion-object (car obj-list))
  (insert "# dplyr::filter(...)\n")
  (let ((pts (point)))
    (insert (mapconcat (lambda (x) (propertize x 'evd-object x))
                       (delete-dups (nreverse obj-list)) ","))
    (goto-char pts)))

(defun ess-view-data--tmpl-mutate (obj-list)
  "Insert the dplyr mutate edit template for OBJ-LIST."
  (insert "# dplyr::mutate(...)\n")
  (let ((pts (point)))
    (insert (mapconcat (lambda (x) (format " = %s" (propertize x 'evd-object x)))
                       (delete-dups (nreverse obj-list)) ","))
    (goto-char pts)))

(defun ess-view-data--tmpl-wide2long (obj-list)
  "Insert the tidyr gather edit template for OBJ-LIST."
  (insert "# tidyr::gather(cols, ...)\n")
  (insert (format "key = %s, value = %s" (car obj-list) (nth 1 obj-list))))

(defun ess-view-data--tmpl-long2wide (obj-list)
  "Insert the tidyr spread edit template for OBJ-LIST."
  (insert "# tidyr::spread(key to column names)\n")
  (insert (format "key = %s, value = %s" (car obj-list) (nth 1 obj-list))))

(defun ess-view-data--tmpl-pivot-longer (obj-list)
  "Insert the tidyr pivot_longer edit template for OBJ-LIST."
  (insert "# tidyr::pivot_longer(cols, names and values to)\n")
  (insert (format "c(), names_to = %s, values_to = %s" (car obj-list) (nth 1 obj-list))))

(defun ess-view-data--tmpl-pivot-wider (obj-list)
  "Insert the tidyr pivot_wider edit template for OBJ-LIST."
  (insert "# tidyr::pivot_wider(names and values from)\n")
  (insert (format "names_from = %s, values_from = %s" (car obj-list) (nth 1 obj-list))))

(defun ess-view-data--tmpl-summarise (obj-list)
  "Insert the dplyr summarise edit template for OBJ-LIST."
  (insert "# %> ... \n# Not limited to function summarise\n")
  (insert "summarise(")
  (insert (mapconcat (lambda (x) (format "%s" (propertize x 'evd-object x)))
                     (delete-dups (nreverse obj-list)) ","))
  (insert ", n = n())"))

(defun ess-view-data--tmpl-reset (obj-list)
  "Insert the reset edit template (OBJ-LIST is the history string)."
  (insert "# reset\n")
  (insert obj-list))

(defun ess-view-data--tmpl-dt-filter (obj-list)
  "Insert the data.table filter edit template for OBJ-LIST."
  (setq ess-view-data-completion-object (car obj-list))
  (insert "# DT[...,]\n")
  (let ((pts (point)))
    (insert (mapconcat (lambda (x) (propertize x 'evd-object x))
                       (delete-dups (nreverse obj-list)) "&"))
    (goto-char pts)))

(defun ess-view-data--tmpl-dt-mutate (obj-list)
  "Insert the data.table mutate edit template for OBJ-LIST."
  (insert "# DT[,`:=`(%s)]\n")
  (let ((pts (point)))
    (insert (mapconcat (lambda (x) (format " = %s" (propertize x 'evd-object x)))
                       (delete-dups (nreverse obj-list)) ","))
    (goto-char pts)))

(defun ess-view-data--tmpl-dt-wide2long (obj-list)
  "Insert the data.table melt edit template for OBJ-LIST."
  (insert "# melt(DT, ...)\n")
  (insert (format "id.vars = c(\"%s\"), measure = col to fill, variable.name = , value.name = c(\"%s\")"
                  (car obj-list) (nth 1 obj-list))))

(defun ess-view-data--tmpl-dt-long2wide (obj-list)
  "Insert the data.table dcast edit template for OBJ-LIST."
  (insert "# dcast(DT, ...)\n")
  (insert (format "id? ~ %s, value.var = c(\"%s\")" (car obj-list) (nth 1 obj-list))))

(defun ess-view-data--tmpl-dt-summarise (obj-list)
  "Insert the data.table summarise edit template for OBJ-LIST."
  (insert "# DT[...] \n# Not limited to function summarise\n")
  (insert ".[, .( ), by = .(")
  (insert (mapconcat (lambda (x) (format "%s" (propertize x 'evd-object x)))
                     (delete-dups (nreverse obj-list)) ","))
  (insert ")]"))

(defun ess-view-data--create-indirect-buffer
    (backend type fun obj-list temp-object parent-buf proc-name)
  "Create an edit-indirect buffer for BACKEND and return it.

TYPE is the action type, e.g., update, reset, summarise.  FUN is the
action verb.  OBJ-LIST are the selected columns (or the history string
for reset).  TEMP-OBJECT is the temporary data name, PARENT-BUF the
view buffer and PROC-NAME the associated ESS process.  The buffer
content is filled from `ess-view-data--template-table'."
  (let* ((buf (get-buffer-create (format ess-view-data-source-buffer-name-format temp-object)))
         (templates (alist-get backend ess-view-data--template-table))
         (template (alist-get fun templates))
         (header (or (alist-get 'header templates) ""))
         (default (alist-get 'default templates)))
    (with-current-buffer buf
      (ess-r-mode)
      (set-buffer-modified-p nil)
      (setq ess-view-data--parent-buffer parent-buf)
      (setq ess-view-data--reset-buffer-p t)
      (setq ess-view-data--action `((:type . ,type) (:function . ,fun)))
      (insert header)
      (insert "# Line started with `#' will be omitted\n")
      (insert "# Don't comment code as all code will be wrapped in one line\n")
      (if (functionp template)
          (funcall template obj-list)
        (insert (or default ""))
        (let ((pts (point)))
          (insert (ess-view-data--join-cols obj-list))
          (goto-char pts)))
      (setq ess-local-process-name proc-name)
      (setq ess-view-data-temp-object
            (buffer-local-value 'ess-view-data-temp-object parent-buf))
      (ess-view-data-edit-mode))
    (select-window (display-buffer buf))))

;;; * print-backend: print
(defvar ess-view-data--print-format
  (concat
   (format
    (concat
     "op.tmp <- options(\"width\", \"tibble.width\", \"crayon.enabled\");"
     "options(tibble.width = Inf, width = %d, crayon.enabled = FALSE);")
    ess-view-data-options-width)
   "print(%s, n = nrow(%s));"
   "options(op.tmp)")
  "Format string for print.")

(defvar ess-view-data--print-format-with-crayon
  (concat
   (format
    (concat
     "op.tmp <- options(\"width\", \"tibble.width\", \"crayon.enabled\");"
     "options(tibble.width = Inf, width = %d, crayon.enabled = TRUE);")
    ess-view-data-options-width)
   "print(%s, n = nrow(%s));"
   "options(op.tmp)")
  "Format string for print, with crayon.enabled for tibble.")

(cl-defmethod ess-view-data--do-print ((_backend (eql print)))
  "Do print using print."
  (if ess-view-data-tibble-crayon-enabled-p
      ess-view-data--print-format-with-crayon
    ess-view-data--print-format))

;;; * kable-backend: kable
(defvar ess-view-data--kable-format
  (concat
   (format
    (concat
     "op.tmp <- options(\"width\", \"tibble.width\", \"crayon.enabled\");"
     "options(tibble.width = Inf, width = %d, crayon.enabled = FALSE);")
    ess-view-data-options-width)
   "print(knitr::kable(%s, n = nrow(%s)));"
   "options(op.tmp)")
  "Format string for kable.")

(cl-defmethod ess-view-data--do-print ((_backend (eql kable)))
  "Do print using kable."
  ess-view-data--kable-format)


;;; * backend: dplyr

;;; ** Initialization
(cl-defmethod ess-view-data--initialize-backend ((_backend (eql dplyr)) proc-name proc)
  "Initialization.

Initializing the history of operations, make temp object.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (let ((obj-space-p (string-match-p ess-view-data-objname-regex ess-view-data-object))
        (obj-back-quote-p (string-match-p "`" ess-view-data-object))
        (obj-back-quote (replace-regexp-in-string "`" "" ess-view-data-object)))
  ;; Initializing the temporary object, for stepwise
  (when (or (null ess-view-data-temp-object)
            (not (ess-view-data--temp-exists-p proc)))
    ;; The temp object is missing in R (e.g. the R session was
    ;; restarted); rebuild it from the source object and reset the
    ;; verb chain so the history matches what R actually holds.
    (unless ess-view-data-temp-object
      (setq ess-view-data-temp-object
            (format (cond (obj-back-quote-p "`%s`")
                          (obj-space-p "`%s`")
                          (t "`%s`"))
                    (make-temp-name obj-back-quote))))
    (setq ess-view-data-history
          (format (cond (obj-back-quote-p "as_tibble(%s)")
                        (obj-space-p "as_tibble(`%s`)")
                        (t "as_tibble(%s)"))
                  ess-view-data-object))
    (setq ess-view-data-page-number 0)
    (when (and proc-name proc
               (not (process-get proc 'busy)))
      (ess-command (concat "{suppressPackageStartupMessages(require(dplyr)); "
                           ;; ess-command using local 2021-12-04
                           ess-view-data-temp-object " <<- as_tibble("
                           (format (cond (obj-back-quote-p "`%s`")
                                         (obj-space-p "`%s`")
                                         (t "`%s`"))
                                   obj-back-quote)
                           ")}\n")
                   nil nil nil nil proc))))
  (cl-pushnew ess-view-data-temp-object ess-view-data-temp-object-list)
  (delete-dups ess-view-data-temp-object-list)
  (ess-view-data--invalidate-completion (current-buffer))
  (ess-view-data--ensure-protocol proc))


(declare-function csv-header-line "csv-mode")

(cl-defmethod ess-view-data--header-line ((_backend (eql dplyr)))
  "Make header-line for dplyr.

R text output starts with trace notes and tibble meta lines (rows
beginning with `+', `#' or an ANSI escape sequence).  Count those
lines so the header is anchored to the first data row, then let
csv-mode build the header-line from that row."
  (goto-char (point-min))
  (let ((lin 1))
    ;; Skip meta/separator lines: `+--' table separators, `#' tibble
    ;; annotations and ANSI colored header rows.
    (while (search-forward-regexp "^\\([+]\\|#\\|[[].+?#\\)" nil t)
      (forward-line)
      (setq lin (1+ lin)))
    (unless (fboundp 'csv-header-line) (require 'csv-mode nil t))
    (when (fboundp 'csv-header-line)
      (with-no-warnings (setq csv--header-line nil))
      (with-no-warnings (csv-header-line lin))))
  (goto-char (point-min)))

(cl-defmethod ess-view-data-get-total-page ((_backend (eql dplyr)) proc-name proc)
  "Get total number of pages of the current object (data.frame/tibble/data.table).

If `ess-view-data-maxprint-p' is nil, it will show 100 rows/lines
per page for dplyr+print/kable.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (ess-view-data--get-total-page ess-view-data-rows-per-page proc-name proc))



(cl-defmethod ess-view-data-do-kill-buffer-hook ((_backend (eql dplyr)) proc-name proc)
  "Functions to run after `kill-buffer' on '*R Data View' buffer.

The default is to rm the temporary object.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (ess-view-data--rm-temp-object proc-name proc))


;;; ** Utilities
(cl-defmethod ess-view-data--do-update ((_backend (eql dplyr)) fun action)
  "Update the data frame by dplyr stepwisely.

Optional argument FUN What to do with the data, e.g.,
verb like select, filter, and etc..
Optional argument ACTION Parameter (R script) for FUN, e.g., columns for select."
  (let (cmdhist cmd result)
    (setq cmdhist (ess-view-data--verb-code 'dplyr fun action))
    (setq ess-view-data-page-number 0)
    (setq ess-view-data--render-object nil)
    (setq cmd (ess-view-data--update-cmd cmdhist))
    (setq result (cons cmdhist cmd))
    result))


(cl-defmethod ess-view-data--do-summarise ((_backend (eql dplyr)) fun action)
  "Do summarising by dplyr stepwisely, without modify the data frame.

Optional argument FUN What to do with the data, e.g.,
verb like count, unique, and etc..
Optional argument ACTION Parameter (R script) for FUN, e.g., columns for count."
  (let (cmdhist cmd result)
    (setq cmdhist (ess-view-data--verb-code 'dplyr fun action))
    (setq ess-view-data--render-object
          (concat ess-view-data-temp-object cmdhist))
    (setq cmd (unless (ess-view-data--display-table-p)
                (ess-view-data--summarise-cmd cmdhist)))
    (setq result (cons cmdhist cmd))
    result))

(cl-defmethod ess-view-data--do-reset ((_backend (eql dplyr)) action)
  "Update the data frame by dplyr stepwisely.

Optional argument ACTION R script to reset the view process,
which will become the cmd history."
  (let (cmdhist cmd result)
    (setq cmdhist action)
    (setq ess-view-data-page-number 0)
    (setq ess-view-data--render-object nil)
    (setq cmd (ess-view-data--reset-cmd cmdhist))
    (setq result (cons cmdhist cmd))
    result))

(cl-defmethod ess-view-data-do-goto-page ((_backend (eql dplyr)) page &optional pnumber)
  "Goto PAGE.

Optional argument PNUMBER The page number to go to."
  (let (cmd result)
    (setq ess-view-data-page-number (ess-view-data--page-number page pnumber))
    (setq ess-view-data--render-object nil)
    (setq cmd (unless (ess-view-data--display-table-p)
                (ess-view-data--render-page)))
    (setq result (cons nil cmd))
    result))

(defvar-local ess-local-process-name nil)


;;; * backend: dplyr+DT


(defcustom ess-view-data-DT-rows-per-page 1000
  "Rows per page for DT."
  :type 'integer
  :group 'ess-view-data)

(defcustom ess-view-data-cache-directory
  (expand-file-name (format "ess-view-data-%d" (user-uid))
		    temporary-file-directory)
  "The base directory, where the cache files (e.g., html files from DT)
will be saved."
  :type 'directory
  :group 'ess-view-data)



(defun ess-view-data-make-safe-dir (dir)
  "This is from `doc-view-make-safe-dir'.
Just to try create a temporary directory to cache the DT files.

Argument DIR name of temporary dir."
  (condition-case nil
      ;; Create temp files with strict access rights.  It's easy to
      ;; loosen them later, whereas it's impossible to close the
      ;; time-window of loose permissions otherwise.
      (with-file-modes #o0700 (make-directory dir))
    (file-already-exists
     (when (file-symlink-p dir)
       (error "Danger: %s points to a symbolic link" dir))
     ;; In case it was created earlier with looser rights.
     ;; We could check the mode info returned by file-attributes, but it's
     ;; a pain to parse and it may not tell you what we want under
     ;; non-standard file-systems.  So let's just say what we want and let
     ;; the underlying C code and file-system figure it out.
     ;; This also ends up checking a bunch of useful conditions: it makes
     ;; sure we have write-access to the directory and that we own it, thus
     ;; closing a bunch of security holes.
     (condition-case error
	 (set-file-modes dir #o0700)
       (file-error
	(error
	 (format "Unable to use temporary directory %s: %s"
		 dir (mapconcat #'identity (cdr error) " "))))))))


;;; ** Initialization
(cl-defmethod ess-view-data--initialize-backend ((_backend (eql dplyr+DT)) proc-name proc)
  "Initialization.

Initializing the history of operations, make temp object.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (let ((obj-space-p (string-match-p ess-view-data-objname-regex ess-view-data-object))
        (obj-back-quote-p (string-match-p "`" ess-view-data-object))
        (obj-back-quote (replace-regexp-in-string "`" "" ess-view-data-object)))
  ;; Initializing the temporary object, for stepwise
  (when (or (null ess-view-data-temp-object)
            (not (ess-view-data--temp-exists-p proc)))
    ;; The temp object is missing in R (e.g. the R session was
    ;; restarted); rebuild it from the source object and reset the
    ;; verb chain so the history matches what R actually holds.
    (unless ess-view-data-temp-object
      (setq ess-view-data-temp-object
            (format (cond (obj-back-quote-p "`%s`")
                          (obj-space-p "`%s`")
                          (t "`%s`"))
                    (make-temp-name obj-back-quote))))
    (setq ess-view-data-history
          (format (cond (obj-back-quote-p "as_tibble(%s)")
                        (obj-space-p "as_tibble(`%s`)")
                        (t "as_tibble(%s)"))
                  ess-view-data-object))
    (setq ess-view-data-page-number 0)
    (ess-view-data-make-safe-dir ess-view-data-cache-directory)
    (when (and proc-name proc
               (not (process-get proc 'busy)))
      (ess-command (concat "{suppressPackageStartupMessages(require(dplyr));"
                           "suppressPackageStartupMessages(require(DT)); "
                           ess-view-data-temp-object " <<- as_tibble("
                           (format (cond (obj-back-quote-p "`%s`")
                                         (obj-space-p "`%s`")
                                         (t "`%s`"))
                                   obj-back-quote)
                           ")}\n")
                   nil nil nil nil proc))))
  (cl-pushnew ess-view-data-temp-object ess-view-data-temp-object-list)
  (delete-dups ess-view-data-temp-object-list)
  (ess-view-data--invalidate-completion (current-buffer))
  (ess-view-data--ensure-protocol proc))


(cl-defmethod ess-view-data--header-line ((_backend (eql dplyr+DT)))
  "Make header-line for dplyr+DT."
  (goto-char (point-min))
  (browse-url (format "%s/%s.html" ess-view-data-cache-directory
                      (replace-regexp-in-string "`" "" ess-view-data-temp-object))))


(cl-defmethod ess-view-data-get-total-page ((_backend (eql dplyr+DT)) proc-name proc)
  "Get the total number of pages.

Get total number of pages of the current object (data.frame/tibble/data.table).

If `ess-view-data-maxprint-p' is nil, it will show 1000 rows/lines per page
for DT.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (ess-view-data--get-total-page ess-view-data-DT-rows-per-page proc-name proc))

(cl-defmethod ess-view-data-do-kill-buffer-hook ((_backend (eql dplyr+DT)) proc-name proc)
  "Functions to run after `kill-buffer' on '*R Data View' buffer.

The default is to rm the temporary object.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (ess-view-data--rm-temp-object proc-name proc))

;;; ** Utilities
(defun ess-view-data--dt-options ()
  "Return the DT table options string honouring `ess-view-data-maxprint-p'."
  (if ess-view-data-maxprint-p
      (format ", options = list(autoWidth = FALSE,pageLength = %d)"
              ess-view-data-DT-rows-per-page)
    (format ", options = list(lengthMenu = c(10,50,100,%d))"
            ess-view-data-DT-rows-per-page)))

(defun ess-view-data--render-page-dt ()
  "Return the R expression rendering the temp object as an HTML DT table."
  (concat
   "local({"
   (format "DT::saveWidget(datatable(%1$s, filter = 'top' %2$s), file = %3$s)\n"
           ess-view-data-temp-object
           (ess-view-data--dt-options)
           (ess-view-data--r-quote-string
            (format "%s/%s.html"
                    ess-view-data-cache-directory
                    (replace-regexp-in-string "`" "" ess-view-data-temp-object))))
   "})\n"))

(defun ess-view-data--update-cmd-dt (cmdhist)
  "Build the DT update command assigning CMDHIST.

In table display mode only the assignment is returned; the page is
rendered separately by `ess-view-data--render'.  In text mode the
DT HTML rendering expression is appended as before."
  (concat ess-view-data-temp-object " <<- " ess-view-data-temp-object cmdhist "; "
          (unless (ess-view-data--display-table-p)
            (ess-view-data--render-page-dt))))

(defun ess-view-data--reset-cmd-dt (cmdhist)
  "Build the DT reset command assigning CMDHIST.

In table display mode only the assignment is returned; the page is
rendered separately by `ess-view-data--render'.  In text mode the
DT HTML rendering expression is appended as before."
  (concat ess-view-data-temp-object " <<- " cmdhist "; "
          (unless (ess-view-data--display-table-p)
            (ess-view-data--render-page-dt))))

(cl-defmethod ess-view-data--do-update ((_backend (eql dplyr+DT)) fun action)
  "Update the data frame by dplyr stepwisely.

Optional argument FUN what to do, e.g. select, filter, etc..
Optional argument ACTION parameters to the FUN."
  (let (cmdhist cmd result)
    (setq cmdhist (ess-view-data--verb-code 'dplyr+DT fun action))
    (setq ess-view-data-page-number 0)
    (setq ess-view-data--render-object nil)
    (setq cmd (ess-view-data--update-cmd-dt cmdhist))
    (setq result (cons cmdhist cmd))
    result))


(cl-defmethod ess-view-data--do-summarise ((_backend (eql dplyr+DT)) fun action)
  "Do summarising by dplyr stepwisely, without modify the data frame.

Optional argument FUN what to do, e.g., count, unique, etc..
Optional argument ACTION parameters to the FUN."
  (let (cmdhist cmd result)
    (setq cmdhist (ess-view-data--verb-code 'dplyr+DT fun action))
    (setq ess-view-data--render-object
          (concat ess-view-data-temp-object cmdhist))
    (setq cmd (unless (ess-view-data--display-table-p)
                (ess-view-data--summarise-cmd cmdhist)))
    (setq result (cons cmdhist cmd))
    result))

(cl-defmethod ess-view-data--do-reset ((_backend (eql dplyr+DT)) action)
  "Update the data frame by dplyr stepwisely.

Optional argument ACTION R script to reset the view process,
which will become the cmd history."
  (let (cmdhist cmd result)
    (setq cmdhist action)
    (setq ess-view-data-page-number 0)
    (setq ess-view-data--render-object nil)
    (setq cmd (ess-view-data--reset-cmd-dt cmdhist))
    (setq result (cons cmdhist cmd))
    result))

(cl-defmethod ess-view-data-do-goto-page ((_backend (eql dplyr+DT)) page &optional pnumber)
  "Goto PAGE.  Just reset `ess-view-data-page-number' when backend is dplyr+DT.

Optional argument PNUMBER The page number to go to."
  (let (result)
    (setq ess-view-data-page-number (ess-view-data--page-number page pnumber))
    (setq ess-view-data--render-object nil)
    (setq result (cons nil (unless (ess-view-data--display-table-p)
                              (ess-view-data--render-page-dt))))
    result))


;;; * backend: data.table

;;; ** Initialization
(cl-defmethod ess-view-data--initialize-backend ((_backend (eql data.table+magrittr)) proc-name proc)
  "Initializing the history of operations.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (let ((obj-space-p (string-match-p ess-view-data-objname-regex ess-view-data-object))
        (obj-back-quote-p (string-match-p "`" ess-view-data-object))
        (obj-back-quote (replace-regexp-in-string "`" "" ess-view-data-object)))
  ;; Initializing the temporary object, for stepwise
  (when (or (null ess-view-data-temp-object)
            (not (ess-view-data--temp-exists-p proc)))
    ;; The temp object is missing in R (e.g. the R session was
    ;; restarted); rebuild it from the source object and reset the
    ;; verb chain so the history matches what R actually holds.
    (unless ess-view-data-temp-object
      (setq ess-view-data-temp-object
            (format (cond (obj-back-quote-p "`%s`")
                          (obj-space-p "`%s`")
                          (t "`%s`"))
                    (make-temp-name obj-back-quote))))
    (setq ess-view-data-history
          (format (cond (obj-back-quote-p "as.data.table(%s)")
                        (obj-space-p "as.data.table(`%s`)")
                        (t "as.data.table(%s)"))
                  ess-view-data-object))
    (setq ess-view-data-page-number 0)
    (when (and proc-name proc
               (not (process-get proc 'busy)))
      (ess-command (concat "{suppressPackageStartupMessages(require(magrittr));"
                           "suppressPackageStartupMessages(require(data.table)); "
                           ess-view-data-temp-object " <<- as.data.table("
                           (format (cond (obj-back-quote-p "`%s`")
                                         (obj-space-p "`%s`")
                                         (t "`%s`"))
                                   obj-back-quote)
                           ")}\n")
                   nil nil nil nil proc))))
  (cl-pushnew ess-view-data-temp-object ess-view-data-temp-object-list)
  (delete-dups ess-view-data-temp-object-list)
  (ess-view-data--invalidate-completion (current-buffer))
  (ess-view-data--ensure-protocol proc))


(cl-defmethod ess-view-data--header-line ((_backend (eql data.table+magrittr)))
  "Make header-line for data.table+magrittr."
  (goto-char (point-min))
  (let ((lin 1))
    (while (search-forward-regexp "^\\([+]\\|#\\)" nil t)
      (forward-line)
      (setq lin (1+ lin)))
    (unless (fboundp 'csv-header-line) (require 'csv-mode nil t))
    (when (fboundp 'csv-header-line)
      (with-no-warnings (setq csv--header-line nil))
      (with-no-warnings (csv-header-line lin))))
  (goto-char (point-min)))

(cl-defmethod ess-view-data-get-total-page ((_backend (eql data.table+magrittr)) proc-name proc)
  "Initializing the history of operations.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (ess-view-data--get-total-page ess-view-data-rows-per-page proc-name proc))



(cl-defmethod ess-view-data-do-kill-buffer-hook ((_backend (eql data.table+magrittr)) proc-name proc)
  "Initializing the history of operations.

Optional argument PROC-NAME The name of associated ESS process,
usually `ess-local-process-name'.
Optional argument PROC The associated ESS process."
  (ess-view-data--rm-temp-object proc-name proc))


(cl-defmethod ess-view-data--do-update ((_backend (eql data.table+magrittr)) fun action)
  "Update the data frame by data.table stepwisely.

Optional argument FUN What to do with the data, e.g.,
verb like select, filter, and etc..
Optional argument ACTION Parameter (R script) for FUN, e.g., columns for select."
  (let (cmdhist cmd result)
    (setq cmdhist (ess-view-data--verb-code 'data.table+magrittr fun action))
    (setq ess-view-data-page-number 0)
    (setq ess-view-data--render-object nil)
    (setq cmd (ess-view-data--update-cmd cmdhist))
    (setq result (cons cmdhist cmd))
    result))


(cl-defmethod ess-view-data--do-summarise ((_backend (eql data.table+magrittr)) fun action)
  "Do summarising by data.table stepwisely, without modify the data frame.

Optional argument FUN What to do with the data, e.g.,
verb like count, unique, and etc..
Optional argument ACTION Parameter (R script) for FUN, e.g., columns for count."
  (let (cmdhist cmd result)
    (setq cmdhist (ess-view-data--verb-code 'data.table+magrittr fun action))
    (setq ess-view-data--render-object
          (concat ess-view-data-temp-object cmdhist))
    (setq cmd (unless (ess-view-data--display-table-p)
                (ess-view-data--summarise-cmd cmdhist)))
    (setq result (cons cmdhist cmd))
    result))

(cl-defmethod ess-view-data--do-reset ((_backend (eql data.table+magrittr)) action)
  "Update the data frame by data.table stepwisely.

Optional argument ACTION R script to reset the view process,
which will become the cmd history."
  (let (cmdhist cmd result)
    (setq cmdhist action)
    (setq ess-view-data-page-number 0)
    (setq ess-view-data--render-object nil)
    (setq cmd (ess-view-data--reset-cmd cmdhist))
    (setq result (cons cmdhist cmd))
    result))

(cl-defmethod ess-view-data-do-goto-page ((_backend (eql data.table+magrittr)) page &optional pnumber)
  "Goto PAGE.

Optional argument PNUMBER The page number to go to."
  (let (cmd result)
    (setq ess-view-data-page-number (ess-view-data--page-number page pnumber))
    (setq ess-view-data--render-object nil)
    (setq cmd (unless (ess-view-data--display-table-p)
                (ess-view-data--render-page)))
    (setq result (cons nil cmd))
    result))


;;; * Table display (Phase 3)

;;; ** Protocol parser

(defun ess-view-data--page-data (text)
  "Parse protocol v1 TEXT into (N ROWS COLS TYPES DATA).
TEXT is the stdout of `ess_view_data_page'.  Returns nil when the
EVD_N header line is missing (the R expression errored).  ROWS, COLS
and TYPES are lists of strings; DATA is a list of rows, each a list
of cell strings.  Empty data has nil ROWS/COLS/TYPES and no rows."
  (let* ((lines (split-string text "\n"))
         (idx (ess-view-data--page-index lines "EVD_N ")))
    (when idx
      (list (string-to-number (substring (nth idx lines) 6))
            (ess-view-data--page-line (nth (1+ idx) lines) "EVD_ROWS ")
            (ess-view-data--page-line (nth (+ 2 idx) lines) "EVD_COLS ")
            (ess-view-data--page-line (nth (+ 3 idx) lines) "EVD_TYPES ")
            (ess-view-data--page-rows (nthcdr (+ 4 idx) lines))))))

(defun ess-view-data--page-index (lines prefix)
  "Index of the first line in LINES starting with PREFIX, or nil."
  (let ((i 0) found)
    (while (and (null found) lines)
      (when (string-prefix-p prefix (car lines))
        (setq found i))
      (setq i (1+ i))
      (setq lines (cdr lines)))
    found))

(defun ess-view-data--page-line (line prefix)
  "TAB-split payload of protocol LINE with PREFIX, or nil."
  (when (and line (string-prefix-p prefix line))
    (split-string (substring line (length prefix)) "\t" t)))

(defun ess-view-data--page-rows (lines)
  "Protocol data rows from LINES, dropping trailing empty lines.
Empty cells are preserved so that columns stay aligned."
  (let ((rows (copy-sequence lines)))
    (while (and rows (equal "" (car (last rows))))
      (setq rows (butlast rows)))
    (delq nil (mapcar (lambda (l) (split-string l "\t")) rows))))

;;; ** Rendering

(defun ess-view-data--type-suffix (type)
  "Header suffix for protocol TYPE."
  (format "[%s]" type))

(defun ess-view-data--numeric-p (type)
  "Return non-nil when TYPE is a right-aligned numeric protocol type."
  (member type '("dbl" "int")))

(defun ess-view-data--table-label (col type)
  "Header label for column COL of protocol TYPE."
  (format "%s [%s]" col type))

(defun ess-view-data--table-lens (cols rows)
  "Vector of the longest `string-width' per column over full ROWS.
COLS only supplies the number of columns; cells beyond it are ignored."
  (let ((lens (make-vector (length cols) 0)))
    (dolist (r rows)
      (let ((i 0))
        (dolist (cell r)
          (when (< i (length lens))
            (aset lens i (max (aref lens i) (string-width cell)))
            (setq i (1+ i))))))
    lens))

(defun ess-view-data--table-widths (cols types rows)
  "Per-column display widths for COLS/TYPES/ROWS.
The width is the cell length capped at `ess-view-data-column-width-cap',
but at least the header label width."
  (let ((lens (ess-view-data--table-lens cols rows)))
    (cl-loop for col in cols
             for ty in types
             for i from 0
             collect (max (min ess-view-data-column-width-cap (aref lens i))
                          (string-width (ess-view-data--table-label col ty))))))

(defun ess-view-data--table-full-widths ()
  "Vector of per-column full display widths for the cached page.
Each width fits the longest full value of that column (uncapped) and
the header label, so a table widened to these widths contains the full
text of every cell.  Return nil when there is no cached data."
  (when (and ess-view-data--table-rows ess-view-data--page-cols)
    (let ((lens (ess-view-data--table-lens ess-view-data--page-cols
                                           ess-view-data--table-rows)))
      (cl-loop for col in ess-view-data--page-cols
               for ty in ess-view-data--table-types
               for i from 0
               collect (max (aref lens i)
                            (string-width (ess-view-data--table-label col ty)))
               into res
               finally (return (vconcat res))))))

(defun ess-view-data--table-cell (cell width)
  "CELL truncated to WIDTH, appending \"...\" when longer."
  (if (> (string-width cell) width)
      (concat (truncate-string-to-width cell (max 0 (- width 3))) "...")
    cell))

(defun ess-view-data--table-format (cols types widths)
  "`tabulated-list-format' vector for COLS/TYPES with WIDTHS.
The raw R column name is stored in the :evd-name plist so that
`ess-view-data-table-sort' can regenerate an `arrange' verb."
  (apply #'vector
         (cl-loop for col in cols
                  for ty in types
                  for w in widths
                  collect (list (ess-view-data--table-label col ty)
                                w t
                                :evd-name col
                                :right-align (ess-view-data--numeric-p ty)))))

(defun ess-view-data--table-entries (rows widths)
  "`tabulated-list-entries' for protocol ROWS with per-column WIDTHS.
Each entry is (ID VECTOR), a two-element list, not a dotted pair:
`tabulated-list-print' relies on `(cadr entry)' being the vector."
  (cl-loop for r in rows
           for i from 0
           collect (list i
                         (apply #'vector
                                (cl-loop for cell in r
                                         for w in widths
                                         collect (ess-view-data--table-cell cell w))))))

(defun ess-view-data--table-sort-key (fmt)
  "`tabulated-list-sort-key' reflecting `ess-view-data--sort-state' in FMT."
  (when ess-view-data--sort-state
    (let ((raw (car ess-view-data--sort-state)))
      (cl-loop for col across fmt
               when (equal (plist-get (nthcdr 3 col) :evd-name) raw)
               return (cons (car col) (cdr ess-view-data--sort-state))))))

(defun ess-view-data--table-print (data)
  "Render parsed page DATA in the current buffer (table mode)."
  (unless (derived-mode-p 'ess-view-data-table-mode)
    (ess-view-data-table-mode))
  (let* ((n (nth 0 data))
         (cols (nth 2 data))
         (types (nth 3 data))
         (rows (nth 4 data)))
    (setq-local ess-view-data-total-page
                (ess-view-data--page-total n ess-view-data-rows-per-page))
    (setq-local ess-view-data-page-number
                (min ess-view-data-page-number (max 0 (1- ess-view-data-total-page))))
    (setq-local ess-view-data--page-cols cols)
    (setq-local ess-view-data--table-rows rows)
    (setq-local ess-view-data--table-types types)
    (if cols
        (let ((widths (ess-view-data--table-widths cols types rows)))
          (setq tabulated-list-format (ess-view-data--table-format cols types widths))
          (ess-view-data--table-entries-current))
      (setq tabulated-list-format (vector (list "No data" 20 t)))
      (setq tabulated-list-entries (list (list 0 (vector (format "%d rows" n))))))
    (setq tabulated-list-sort-key (ess-view-data--table-sort-key tabulated-list-format))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (ess-view-data-mode 1)))

(defun ess-view-data--table-entries-current ()
  "Rebuild `tabulated-list-entries' from the full-row cache.
The truncation width of each column comes from the current
`tabulated-list-format', so widening or narrowing a column reveals or
hides the corresponding part of every cell.  Does nothing outside an
`ess-view-data-table-mode' buffer or when the cache is empty."
  (when (and (derived-mode-p 'ess-view-data-table-mode)
             ess-view-data--table-rows
             tabulated-list-format)
    (let ((widths (cl-loop for col across tabulated-list-format
                           collect (nth 1 col))))
      (setq tabulated-list-entries
            (ess-view-data--table-entries ess-view-data--table-rows widths)))))

(defun ess-view-data--table-column-resized (&rest _)
  "Rebuild entries and reprint after a column resize in ESS-V tables.
Works only in `ess-view-data-table-mode' buffers that still hold the
full-row cache; other tabulated-list buffers are left untouched.
`tabulated-list-widen-current-column' / `-narrow-current-column' print
in update mode from the already-truncated entries, so the rebuilt
entries are printed here from the cache at the new column widths."
  (when (and (derived-mode-p 'ess-view-data-table-mode)
             ess-view-data--table-rows)
    (ess-view-data--table-entries-current)
    (tabulated-list-print t)))

(when (fboundp 'tabulated-list-widen-current-column)
  (advice-add 'tabulated-list-widen-current-column :after
              #'ess-view-data--table-column-resized))
(when (fboundp 'tabulated-list-narrow-current-column)
  (advice-add 'tabulated-list-narrow-current-column :after
              #'ess-view-data--table-column-resized))

(defun ess-view-data--table-error (text)
  "Show protocol failure TEXT in the current table buffer."
  (unless (derived-mode-p 'ess-view-data-table-mode)
    (ess-view-data-table-mode))
  (setq tabulated-list-format (vector (list "Error" 60 t)))
  (setq tabulated-list-entries
        (cl-loop for l in (split-string text "\n" t)
                 for i from 0
                 collect (list i (vector l))))
  (tabulated-list-init-header)
  (tabulated-list-print t))

(defun ess-view-data--table-render-page (buf)
  "Query the current page of BUF from R and render it as a table."
  (let* ((proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (get-process proc-name))
         text data)
    (when (and proc-name proc (not (process-get proc 'busy)))
      ;; R may have been restarted since the helper was sourced; the
      ;; idempotent guard costs one cheap exists check per query.
      (ess-view-data--ensure-protocol proc)
      (setq text (with-current-buffer buf
                   (ess-string-command (ess-view-data--protocol-cmd))))
      (setq data (ess-view-data--page-data text))
      (with-current-buffer buf
        (if data
            (ess-view-data--table-print data)
          (ess-view-data--table-error text))))))

;;; ** Render dispatch and shared refresh

(defun ess-view-data--render (buf)
  "Render the current page of BUF per `ess-view-data-display-backend'.
For `table', query R with the page-data protocol and redisplay the
tabulated list.  For `print'/`kable', do nothing: the text command
embeds the print expression."
  (when (ess-view-data--display-table-p)
    (ess-view-data--table-render-page buf)))

(defun ess-view-data--refresh-view (buf type fun command)
  "Send COMMAND (cons HIST . R-CODE) to R and refresh the view buffer BUF.
TYPE is `update', `reset' or `summarise'; FUN the verb symbol.
Updates the Trace history, page state and dribble log, then re-renders
according to `ess-view-data-display-backend'."
  (let* ((proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (get-process proc-name)))
    (when (and proc-name proc command (cdr command))
      (ess-view-data--run-r
       (concat "{" (cdr command) "}")
       (unless (ess-view-data--display-table-p) buf)
       nil nil proc))
    (ess-write-to-dribble-buffer (format "[ESS-v] %s.\n" (symbol-name fun)))
    (with-current-buffer buf
      (when (memq type '(update reset))
        ;; The temp object changed, so cached column names and values
        ;; are stale; drop them (C3).
        (ess-view-data--invalidate-completion buf)
        (setq ess-view-data-history
              (if (eql type 'reset) (car command)
                (concat ess-view-data-history (car command))))
        (setq ess-view-data-page-number 0))
      (setq ess-view-data--last-command (car command))
      (ess-write-to-dribble-buffer (format "# Trace: %s\n" ess-view-data-history))
      (ess-write-to-dribble-buffer (format "# Last: %s\n" (car command)))
      (if (ess-view-data--display-table-p)
          (ess-view-data--render buf)
        (when (memq type '(update reset))
          (ess-view-data-get-total-page ess-view-data-current-backend proc-name proc))
        (goto-char (point-min))
        (when ess-view-data-show-code
          (insert (format "# Trace: %s\n" ess-view-data-history))
          (insert (format "# Last: %s\n" (car command))))
        (when (memq type '(update reset))
          (unless (or ess-view-data-maxprint-p ess-view-data-show-no-page-number)
            (insert (format "# Page number: %d / %d\n"
                            (1+ ess-view-data-page-number) ess-view-data-total-page))))
        (goto-char (point-min))
        (ess-view-data-mode 1)
        (goto-char (point-min))
        (ess-view-data--header-line ess-view-data-current-backend)))))

;;; ** Table major mode

(defvar ess-view-data-table-mode-map
  (let ((map (make-composed-keymap nil tabulated-list-mode-map)))
    (define-key map "S" #'ess-view-data-table-sort)
    (define-key map "W" #'tabulated-list-widen-current-column)
    (define-key map "v" #'ess-view-data-show-cell-value)
    (define-key map "w" #'ess-view-data-widen-current-column-full)
    (define-key map "a" #'ess-view-data-widen-all-columns-full)
    map)
  "Keymap for `ess-view-data-table-mode'.")

(defvar ess-view-data-table--sort-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'ess-view-data-table-col-sort)
    (define-key map [header-line mouse-2] #'ess-view-data-table-col-sort)
    (define-key map [mouse-1] #'ess-view-data-table-col-sort)
    (define-key map [mouse-2] #'ess-view-data-table-col-sort)
    (define-key map "RET" #'ess-view-data-table-sort)
    map)
  "Header-line sort keymap for `ess-view-data-table-mode'.")

(define-derived-mode ess-view-data-table-mode tabulated-list-mode
  "ESS-V Table"
  "Major mode displaying an R data page as a tabulated list.

The header shows each column with its R type (e.g. \"mpg [dbl]\").
`S' or a header click regenerates a server-side `arrange' verb so
that sorting always applies to the whole data, not just the page."
  (setq-local tabulated-list-sort-key nil)
  (setq-local tabulated-list-sort-button-map ess-view-data-table--sort-button-map)
  (setq buffer-read-only t))

;;; ** Header sort (server-side arrange)

(defun ess-view-data-table--label-raw (label)
  "Raw R column name for header LABEL in `tabulated-list-format'."
  (cl-loop for col across tabulated-list-format
           when (equal (car col) label)
           return (plist-get (nthcdr 3 col) :evd-name)))

;;; ** Cell value and column widening

(defun ess-view-data-show-cell-value ()
  "Show the full value of the cell at point in a read-only buffer.
The popup lists the object name, column, type, row and the complete
cell value, all read from the local page cache with no R round trip.
Kill the popup with `q'.  Only available in the table display."
  (interactive)
  (unless (derived-mode-p 'ess-view-data-table-mode)
    (user-error "ess-view-data-show-cell-value: only available in the table display"))
  (let* ((id (tabulated-list-get-id))
         (label (get-text-property (point) 'tabulated-list-column-name))
         (raw (ess-view-data-table--label-raw label))
         (idx (and raw (cl-position raw ess-view-data--page-cols :test #'equal)))
         (row (and id (nth id ess-view-data--table-rows)))
         (value (and row idx (nth idx row)))
         (type (and idx (nth idx ess-view-data--table-types)))
         (obj (or ess-view-data-object "")))
    (unless value
      (user-error "ess-view-data-show-cell-value: no cell value at point"))
    (let ((buf (get-buffer-create "*ess-view-data-cell*")))
      (with-current-buffer buf
        (special-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "object: %s\n" obj))
          (insert (format "column: %s [%s]\n" raw type))
          (insert (format "row: %d\n\n" id))
          (insert (if (equal value "") "(empty)" value)))
        (goto-char (point-min)))
      (pop-to-buffer buf))))

(defun ess-view-data-widen-current-column-full ()
  "Widen the current column to fit its longest full value.
The new width comes from the full-row cache and is not capped by
`ess-view-data-column-width-cap'.  Only available in the table display."
  (interactive)
  (unless (derived-mode-p 'ess-view-data-table-mode)
    (user-error "ess-view-data-widen-current-column-full: only available in the table display"))
  (let* ((label (get-text-property (point) 'tabulated-list-column-name))
         (n (and label (cl-position label (append tabulated-list-format nil)
                                    :test (lambda (l c) (equal l (car c))))))
         (full (ess-view-data--table-full-widths))
         (w (and full n (aref full n))))
    (unless w
      (user-error "ess-view-data-widen-current-column-full: no column at point"))
    (setf (nth 1 (aref tabulated-list-format n)) w)
    (tabulated-list-init-header)
    (ess-view-data--table-entries-current)
    (tabulated-list-print t)))

(defun ess-view-data-widen-all-columns-full ()
  "Widen every column to fit its longest full value.
After this the whole current page is in the buffer as full text, so
Emacs' built-in isearch (`C-s' / `C-r') can search the full values.
The widths come from the full-row cache and are not capped by
`ess-view-data-column-width-cap'.  Only available in the table display."
  (interactive)
  (unless (derived-mode-p 'ess-view-data-table-mode)
    (user-error "ess-view-data-widen-all-columns-full: only available in the table display"))
  (let ((full (ess-view-data--table-full-widths)))
    (unless full
      (user-error "ess-view-data-widen-all-columns-full: no cached data"))
    (cl-loop for col across tabulated-list-format
             for w across full
             do (setf (nth 1 col) w))
    (tabulated-list-init-header)
    (ess-view-data--table-entries-current)
    (tabulated-list-print t)))

(defun ess-view-data-table--apply-sort (raw desc-p)
  "Arrange the whole data by column RAW; DESC-P for descending.
Generates the backend `sort' verb and runs it through the update
chain, so the table re-renders from a fully sorted data set."
  (let* ((backend ess-view-data-current-backend)
         (desc-fmt (plist-get (alist-get backend ess-view-data-backend-setting) :desc))
         (col (if (and desc-p desc-fmt) (format desc-fmt raw) raw))
         (command (ess-view-data--do-update backend 'sort (list col))))
    (setq ess-view-data--sort-state (cons raw desc-p))
    (ess-view-data--refresh-view (current-buffer) 'update 'sort command)))

(defun ess-view-data-table-sort (&optional n)
  "Sort the whole data by the column at point (server-side arrange).
A second sort on the same column toggles the direction.  With a
numeric prefix argument N, sort the Nth column."
  (interactive "P")
  (let* ((label (if n (car (aref tabulated-list-format n))
                  (get-text-property (point) 'tabulated-list-column-name)))
         (raw (ess-view-data-table--label-raw label)))
    (when raw
      (ess-view-data-table--apply-sort
       raw (not (equal label (car ess-view-data--sort-state)))))))

(defun ess-view-data-table-col-sort (&optional e)
  "Sort the whole data by the column clicked in the header (event E)."
  (interactive "e")
  (let* ((pos (event-start e))
         (obj (posn-object pos))
         (label (get-text-property (if obj (cdr obj) (posn-point pos))
                                   'tabulated-list-column-name
                                   (car obj)))
         (raw (ess-view-data-table--label-raw label)))
    (when raw
      (ess-view-data-table--apply-sort
       raw (not (equal label (car ess-view-data--sort-state)))))))

;;; ** Trace presentation

(defun ess-view-data--mode-line-trace ()
  "Truncated Trace for the mode line; empty when there is no history."
  (if ess-view-data-history
      (let ((s (replace-regexp-in-string " %>% " " | " ess-view-data-history)))
        (if (> (length s) 40)
            (concat " " (substring s 0 37) "...")
          (concat " " s)))
    ""))

(defun ess-view-data-show-history ()
  "Show the full Trace and Last history of the view data.
The history is displayed in a read-only buffer; kill it with `q'."
  (interactive)
  (let ((buf (get-buffer-create "*ess-view-data-history*")))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Trace: %s\n\n" (or ess-view-data-history "")))
        (insert (format "Last: %s\n" (or ess-view-data--last-command ""))))
      (goto-char (point-min)))
    (pop-to-buffer buf)))


;;; * save data

(cl-defmethod ess-view-data-do-save ((_backend (eql write.csv)) file-name)
  "Save the current view data with write.csv.

Optional argument FILE-NAME file name."
  (let (cmd result)
    (setq cmd (format "write.csv(%s, file = %s)\n"
                      ess-view-data-temp-object
                      (ess-view-data--r-quote-string file-name)))
    (setq result (cons nil cmd))
    result))

(cl-defmethod ess-view-data-do-save ((_backend (eql readr::write_csv)) file-name)
  "Save the current view data with readr::write_csv.

Optional argument FILE-NAME file name."
  (let (cmd result)
    (setq cmd (format "readr::write_csv(%s, file = %s)\n"
                      ess-view-data-temp-object
                      (ess-view-data--r-quote-string file-name)))
    (setq result (cons nil cmd))
    result))

(cl-defmethod ess-view-data-do-save ((_backend (eql data.table::fwrite)) file-name)
  "Save the current view data with data.table::fwrite.

Optional argument FILE-NAME file name."
  (let (cmd result)
    (setq cmd (format "data.table::fwrite(%s, file = %s)\n"
                      ess-view-data-temp-object
                      (ess-view-data--r-quote-string file-name)))
    (setq result (cons nil cmd))
    result))


;;; * Completion cache

;; The completion cache (an alist of `(NAME . VALUES)' pairs) is owned
;; by the view buffer.  Edit-indirect buffers reach it through
;; `ess-view-data--parent-buffer', so a second completion from either
;; buffer costs no extra round trip (C3).

(defun ess-view-data--completion-owner ()
  "Return the buffer owning the completion cache.
In an edit-indirect buffer this follows `ess-view-data--parent-buffer';
in the view buffer itself it is the current buffer."
  (or ess-view-data--parent-buffer (current-buffer)))

(defun ess-view-data--completion-get (key)
  "Completion VALUES for KEY from the cache, as a list, or nil.
Vector values written by older code are converted for convenience."
  (let ((value (alist-get key
                          (buffer-local-value
                           'ess-view-data-completion-candidate
                           (ess-view-data--completion-owner)))))
    (when value
      (if (vectorp value) (append value nil) value))))

(defun ess-view-data--completion-put (key value)
  "Store KEY mapped to VALUE in the completion cache of the owner."
  (with-current-buffer (ess-view-data--completion-owner)
    (setf (alist-get key ess-view-data-completion-candidate) value)))

(defun ess-view-data--invalidate-completion (buf)
  "Drop the completion and column caches of the view buffer BUF.
Called after any verb that changes the temp object so stale
candidates are never offered (C3)."
  (with-current-buffer buf
    (setq ess-view-data-completion-candidate nil)
    (setq ess-view-data--page-cols nil)
    (setq ess-view-data--table-rows nil)
    (setq ess-view-data--table-types nil)))

(defun ess-view-data--completion-key (kind name)
  "Return the cache alist key for NAME, namespace-prefixed by KIND.
KIND is `object' or `column'.  The distinct \"obj:\"/\"col:\"
prefixes keep object and column entries from ever colliding in the
shared alist (e.g. a column literally named like the object).  Backticks
are stripped, so `` `my col` '' and \"my col\" map to the same key."
  (intern (concat (if (eql kind 'object) "obj:" "col:")
                  (replace-regexp-in-string "`" "" name))))

(defun ess-view-data--completion-cols ()
  "Cached column names of the temp object, as a list."
  (ess-view-data--completion-get
   (ess-view-data--completion-key 'object ess-view-data-temp-object)))

(defun ess-view-data--fetch-colnames (&optional obj)
  "Fetch the column names of OBJ (default the temp object) from R.
Text backends fall back to a light `names()' query."
  (let* ((buf (current-buffer))
         (proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (and (stringp proc-name) (get-process proc-name))))
    (when (and proc-name proc (not (process-get proc 'busy)))
      (ess-get-words-from-vector
       (concat "names(" (or obj ess-view-data-temp-object) ")\n")))))

(defun ess-view-data--fetch-column-values (col &optional obj)
  "Fetch the unique values of COL in OBJ (default the temp object).
Values are queried per column via jsonlite, so a wide table is never
dumped at once."
  (let* ((buf (current-buffer))
         (proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (and (stringp proc-name) (get-process proc-name)))
         (cmd (format "jsonlite::toJSON(as.character(unique(%s[[%s]])))\n"
                      (or obj ess-view-data-temp-object)
                      (ess-view-data--r-quote-string
                       (replace-regexp-in-string "`" "" col)))))
    (when (and proc-name proc (not (process-get proc 'busy)))
      (append (json-read-from-string (ess-string-command cmd)) nil))))

(defun ess-view-data--ensure-completion-cols (&optional df)
  "Return the column names of DF (default the temp object), cached.
Table mode reuses the column names of the last page query, so the
first completion in a view buffer costs no extra round trip; other
backends fall back to `ess-view-data--fetch-colnames'."
  (let* ((obj (or df ess-view-data-temp-object))
         (obj-key (ess-view-data--completion-key 'object obj)))
    (or (ess-view-data--completion-get obj-key)
        (let* ((page-cols (and (null df)
                               (with-current-buffer (ess-view-data--completion-owner)
                                 ess-view-data--page-cols)))
               (cols (or page-cols (ess-view-data--fetch-colnames obj))))
          ;; Do not cache a failed fetch (busy process), so the next
          ;; call retries instead of pinning an empty candidate list.
          (when cols
            (ess-view-data--completion-put obj-key cols))
          cols))))

(defun ess-view-data--column-values (col &optional df)
  "Return the unique values of COL in DF (default the temp object).
The first access for COL fetches from R and caches the result per
column; later accesses, also from the edit-indirect buffer, hit the
cache."
  (let* ((obj (or df ess-view-data-temp-object))
         (key (ess-view-data--completion-key 'column col)))
    (or (ess-view-data--completion-get key)
        (let ((vals (ess-view-data--fetch-column-values col obj)))
          ;; As in `ess-view-data--ensure-completion-cols', a failed
          ;; fetch (busy process) is not cached.
          (when vals
            (ess-view-data--completion-put key vals))
          vals))))


;;; * For completion
(cl-defmethod ess-view-data-do-complete-data ((_backend (eql jsonlite)) &optional dataframe)
  "Return the completion alist for DATAFRAME (default the temp object).
Column names come from the column layer
\(`ess-view-data--ensure-completion-cols'); unique values are fetched
per column through `ess-view-data--column-values' instead of dumping
every column in a single jsonlite call."
  (let* ((obj (or dataframe ess-view-data-temp-object))
         (obj-key (intern (replace-regexp-in-string "`" "" obj)))
         (cols (ess-view-data--ensure-completion-cols dataframe))
         result)
    (setq result (list (cons obj-key cols)))
    (dolist (col cols)
      (setq result (nconc result (list (cons (intern col)
                                             (ess-view-data--column-values
                                              col dataframe))))))
    result))



(defun ess-view-data--previous-complete-object (prop)
  "Search for the object.

Argument PROP text property to get the object for completion."
  (let (prop-value)
    (while (progn
             (goto-char (previous-single-char-property-change (point) prop))
             (not (or (setq prop-value (get-text-property (point) prop))
                      (eobp)
                      (bobp)))))
    prop-value))



(defun ess-view-data-complete-data (&optional arg)
  "Ess view data do complete.

Optional argument ARG if non-nil, it will read the which variable
to be completed."
  (interactive "P")
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let (evd-object)

    (if (or arg (null (save-excursion
                        (save-restriction
                          (setq evd-object (ess-view-data--previous-complete-object 'evd-object))))))
        (progn
          (let* ((possible-completions (ess-r-get-rcompletions))
                 (token-string (or (car possible-completions) ""))
                 (start (- (point) (length token-string)))
                 (end (point)))
            (setq evd-object
                  (funcall ess-view-data-read-string
                           "Variable: "
                           (delete-dups (ess-view-data--ensure-completion-cols))
                           nil nil token-string))
            (delete-region start end)
            ;; propertize
            (insert (propertize evd-object 'evd-object evd-object))))

      (if evd-object
          (let* ((possible-completions (ess-r-get-rcompletions))
                 (token-string (or (car possible-completions) ""))
                 (start (- (point) (length token-string)))
                 (end (point))
                 com)
            (setq com
                  (funcall ess-view-data-read-string
                           "Value: "
                           (delete-dups (ess-view-data--column-values evd-object))
                           nil nil token-string))
            (delete-region start end)
            (insert com))))))


(defun ess-view-data-insert-all-cols ()
  "Insert all column/variable names."
  (interactive)
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let ((cols (delete-dups (ess-view-data--ensure-completion-cols))))
    (when cols
      (insert (mapconcat (lambda (x) (propertize x 'evd-object x))
                         cols ",")))))


(defun ess-view-data-insert-all-values ()
  "Insert all column/variable names."
  (interactive)
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let (evd-object)
    (save-excursion
      (save-restriction
        (setq evd-object (ess-view-data--previous-complete-object 'evd-object))))

    (if evd-object
        (let ((obj-list (delete-dups (ess-view-data--column-values evd-object))))
          (insert (format "\"%s\""(mapconcat 'identity obj-list ",")))))))


(defun ess-view-data-complete-object ()
  "Ess view data do complete object name."
  (interactive)
  (ess-view-data-complete-data 1))

(defun ess-view-data-complete-set-object ()
  "Set object for completion."
  (interactive)
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let* ((possible-completions (ess-r-get-rcompletions))
         (token-string (or (car possible-completions) ""))
         object)
    (setq object
          (funcall ess-view-data-read-string
                   "Variable: "
                   (delete-dups (ess-view-data--ensure-completion-cols))
                   nil nil token-string))
    (insert (propertize " " 'evd-object object))))

;;; * Export function

(defun ess-view-data-do-commit ()
  "Commit the modifications done in an edit-indirect buffer.

Can be called only when the current buffer is an edit-indirect buffer."
  (interactive)
  (let* ((parent-buffer ess-view-data--parent-buffer)
         (proc-name (buffer-local-value 'ess-local-process-name parent-buffer))
         (proc (get-process proc-name))
         (fill-column most-positive-fixnum)
         (fun (alist-get :function ess-view-data--action))
         (type (alist-get :type ess-view-data--action))
         command)
    ;; Keep the edit buffer when R is busy: killing it first would
    ;; discard the user's edits.  Signal a `user-error' instead so
    ;; that they can retry once R is idle again (A6).
    (when (and proc-name proc (process-get proc 'busy))
      (user-error "R process %s is busy; wait for it to finish and retry"
                  (process-name proc)))
    (with-current-buffer (current-buffer)
      (when ess-view-data--reset-buffer-p
        (save-excursion
          (save-match-data
            (goto-char (point-min))
            (flush-lines "^#")
            (fill-region (point-min) (point-max))
            (setq command (buffer-substring-no-properties (point-min) (point-max)))
            ;; make command in one line to avoid the print of ` + ' in the output buffer
            (setq command (replace-regexp-in-string "\n+" " " command))))
        (kill-buffer)))

    (pop-to-buffer parent-buffer)

    (when (and proc-name proc command)
      (setq command
            (pcase type
              ('update
               (ess-view-data--do-update ess-view-data-current-backend fun command))
              ('summarise
               (ess-view-data--do-summarise ess-view-data-current-backend fun command))
              ('reset
               (ess-view-data--do-reset ess-view-data-current-backend command))))
      (ess-view-data--refresh-view parent-buffer type fun command))))


(defun ess-view-data-do-apply (type fun indirect &optional desc trans prompt)
  "Update data frame.

Argument TYPE Action type, e.g., update, reset, summarise.
Argument FUN Action function to do with data, e.g., select, count, etc..
Argument INDIRECT Indirect buffer to edit the parameters or verbs.
Optional argument DESC if non-nil, then descending.
Optional argument TRANS if non-nil, read key and value for transform.
Optional argument PROMPT prompt for `read-string'."
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (unless ess-view-data-object
    (error "No data object is being viewed; run `ess-view-data-print' first"))
  (let* ((buf (current-buffer))
         (proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (get-process proc-name))
         (obj " ")
         obj-list
         objs
         objs2
         command)
    ;; Initializing backed
    (ess-view-data--initialize-backend ess-view-data-current-backend proc-name proc)
    ;; variables
    (if (eql 'reset fun)
        ;; reset
        (ess-view-data--create-indirect-buffer ess-view-data-current-backend
                                               type fun
                                               ess-view-data-history
                                               ess-view-data-temp-object buf proc-name)
      ;; other actions
    (when (and proc-name proc
               (not (process-get proc 'busy)))
      (if prompt
          ;; general read-string
          (setq obj-list (read-string prompt))
        ;; read column names
        (setq objs (ess-get-words-from-vector
                    (concat "colnames(" ess-view-data-temp-object ")\n"))) ;; or "ls()"
        ;; In case the colname is not simple
        (setq objs (mapcar (lambda (x)
                             (format (if (string-match-p ess-view-data-objname-regex x)
                                         "`%s`" "%s")
                                     x))
                           objs))
        (if desc
            (setq objs (apply 'append
                              `(,objs
                                ,(mapcar (lambda (x) (format desc x)) objs)))))
        (if trans
            (progn
              (setq obj (funcall ess-view-data-read-string "key"  objs))
              (setq objs2 (funcall ess-view-data-read-string "value"  objs))
              (setq obj-list (list obj objs2)))
          (if (equal ess-view-data-read-string 'completing-read)
              (setq obj-list (nreverse (completing-read-multiple "Select Variables: " objs)))
            (while (not (equal obj ""))
              (setq obj (funcall ess-view-data-read-string
                                 (format "Variable (%s), C-j to finish"
                                         (mapconcat 'identity
                                                    (setq objs2 (nreverse objs2))
                                                    ","))
                                 objs))
              (unless (equal obj "")
                (setq objs (delete obj objs))
                (cl-pushnew obj obj-list)
                (cl-pushnew obj objs2))))))
      (if indirect
          (when obj-list
            (ess-view-data--create-indirect-buffer ess-view-data-current-backend
                                                   type fun obj-list
                                                   ess-view-data-temp-object
                                                   buf proc-name))
        (when obj-list
          (setq command
                (pcase type
                  ('update
                   (ess-view-data--do-update ess-view-data-current-backend fun obj-list))
                  ('summarise
                   (ess-view-data--do-summarise ess-view-data-current-backend fun obj-list)))))
        (when (and proc-name proc command)
          (ess-view-data--refresh-view buf type fun command)))))))




(defun ess-view-data-select ()
  "Select columns/variables."
  (interactive)
  (ess-view-data-do-apply 'update 'select nil nil))

(defun ess-view-data-unselect ()
  "Unselect columns/variables."
  (interactive)
  (ess-view-data-do-apply 'update 'unselect nil nil))

(defun ess-view-data-sort ()
  "Sort columns/variables."
  (interactive)
  (ess-view-data-do-apply
   'update 'sort nil
   (plist-get (alist-get ess-view-data-current-backend ess-view-data-backend-setting) :desc)))

(defun ess-view-data-group ()
  "Group columns/variables."
  (interactive)
  (ess-view-data-do-apply 'update 'group nil nil))

(defun ess-view-data-ungroup ()
  "Ungroup columns/variables."
  (interactive)
  (ess-view-data-do-apply 'update 'ungroup nil nil))


;; filter
(defun ess-view-data-filter ()
  "Do filter."
  (interactive)
  (ess-view-data-do-apply 'update 'filter t nil))

;; mutate
(defun ess-view-data-mutate ()
  "Do mutate."
  (interactive)
  (ess-view-data-do-apply 'update 'mutate t nil))

(defun ess-view-data-slice ()
  "Slice."
  (interactive)
  (ess-view-data-do-apply
   'update 'slice nil nil nil
   (plist-get (alist-get ess-view-data-current-backend ess-view-data-backend-setting) :slice)))


;; wide2long
(defun ess-view-data-wide2long ()
  "Do wide2long."
  (interactive)
  (ess-view-data-do-apply 'update 'wide2long t nil t))


;; long2wide
(defun ess-view-data-long2wide ()
  "Do long2wide."
  (interactive)
  (ess-view-data-do-apply 'update 'long2wide t nil t))

;; update
(defun ess-view-data-update ()
  "Do update."
  (interactive)
  (ess-view-data-do-apply 'update 'update t nil))

;;; ** reset
(defun ess-view-data-reset ()
  "Do filter."
  (interactive)
  (ess-view-data-do-apply 'reset 'reset t nil))


;;; ** summarise
(defun ess-view-data-unique ()
  "Unique."
  (interactive)
  (ess-view-data-do-apply 'summarise 'unique nil nil))


(defun ess-view-data-count ()
  "Count."
  (interactive)
  (ess-view-data-do-apply 'summarise 'count nil nil))

(defun ess-view-data-skimr ()
  "Skim the data with skimr."
  (interactive)
  (ess-view-data-do-apply 'summarise 'skimr nil nil))

(defun ess-view-data-summarise ()
  "Ess view data do summarise."
  (interactive)
  (ess-view-data-do-apply 'summarise 'summarise t nil))

(defun ess-view-data-overview ()
  "Overview the data with skimr over all columns.

Equivalent to `ess-view-data-skimr' with no columns selected (A9)."
  (interactive)
  (ess-view-data-do-apply 'summarise 'skimr-all nil nil))


(defun ess-view-data-verbs (verb)
  "Select the VERB to do."
  (interactive (list (completing-read
                      "verb: "
				      (append ess-view-data-verb-update-list
                              ess-view-data-verb-update-indirect-list
                              ess-view-data-verb-summarise-list
                              ess-view-data-verb-summarise-indirect-list
                              '("reset"))
				      nil t)))
  (cond
   ((member verb ess-view-data-verb-update-list)
    (ess-view-data-do-apply 'update (intern verb) nil nil))
   ((member verb ess-view-data-verb-update-indirect-list)
    (ess-view-data-do-apply 'update (intern verb) t nil))
   ((member verb ess-view-data-verb-summarise-list)
    (ess-view-data-do-apply 'summarise (intern verb) nil nil))
   ((member verb ess-view-data-verb-summarise-indirect-list)
    (ess-view-data-do-apply 'summarise (intern verb) t nil))
   ((string= verb "reset")
    (ess-view-data-do-apply 'reset 'reset t nil))))



(defun ess-view-data-commit-abort ()
  "Kill the edit-indirect buffer."
  (interactive)
  (kill-buffer))



;; scroll data

;;; ** goto page
(defun ess-view-data-goto-page (page &optional pnumber)
  "Goto PAGE.
Optional argument PNUMBER page number to go."
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let* ((buf (current-buffer))
         (proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (get-process proc-name))
         command)
    ;; Initializing backed
    (ess-view-data--initialize-backend ess-view-data-current-backend proc-name proc)

    (setq command
          (ess-view-data-do-goto-page ess-view-data-current-backend page pnumber))

    (when (and proc-name proc command (cdr command))
      (ess-view-data--run-r (concat "{" (cdr command) "}") buf nil nil proc))
    (with-current-buffer buf
      (if (ess-view-data--display-table-p)
          (ess-view-data--render buf)
        (goto-char (point-min))
        (when ess-view-data-show-code
          (insert (format "# Trace: %s\n" ess-view-data-history)))
        (unless (or ess-view-data-maxprint-p ess-view-data-show-no-page-number)
          (insert (format "# Page number: %d / %d\n"
                          (1+ ess-view-data-page-number)
                          ess-view-data-total-page)))
        (goto-char (point-min))
        (ess-view-data-mode 1)
        (goto-char (point-min))
        (ess-view-data--header-line ess-view-data-current-backend)))))


(defun ess-view-data-goto-next-page ()
  "Ess view data do select."
  (interactive)
  (ess-view-data-goto-page 'next))

(defun ess-view-data-goto-previous-page ()
  "Ess view data do select."
  (interactive)
  (ess-view-data-goto-page 'previous))

(defun ess-view-data-goto-first-page ()
  "Ess view data do select."
  (interactive)
  (ess-view-data-goto-page 'first))

(defun ess-view-data-goto-last-page ()
  "Ess view data do select."
  (interactive)
  (ess-view-data-goto-page 'last))


(defun ess-view-data-goto-page-number (&optional pnumber)
  "Goto page number PNUMBER (1-based).

Optional argument PNUMBER The page number to go to."
  (interactive "NGoto page:")
  (ess-view-data-goto-page 'page (1- pnumber)))


;; save
(defun ess-view-data-save ()
  "Ess view data do save."
  (interactive)
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let* ((buf (current-buffer))
         (proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (get-process proc-name))
         file-name
         command)
    ;; Initializing backed
    (ess-view-data--initialize-backend ess-view-data-current-backend proc-name proc)
    ;; slice variables
    (setq file-name (find-file-read-args "Find file: "
                                         (confirm-nonexistent-file-or-buffer)))
    (if file-name
        (setq command
              (ess-view-data-do-save ess-view-data-current-save-backend (car file-name))))
    (when (and proc-name proc command)
      (ess-view-data--run-r (concat "{" (cdr command) "}") nil nil nil proc)
      (ess-write-to-dribble-buffer "[ESS-v] Saved.\n")
      (ess-write-to-dribble-buffer (format "# Trace: %s\n" ess-view-data-history))
      (ess-write-to-dribble-buffer (format "# Last: %s\n" (car command)))
      (with-current-buffer buf
        (goto-char (point-min))))))



;; utilities
(defun ess-view-data-quit ()
  "Quit from ess-view-data."
  (interactive)
  (kill-buffer))

(defun ess-view-data-kill-buffer-hook ()
  "Hook for `kill-buffer' to clean environment."
  (let* ((proc-name (buffer-local-value 'ess-local-process-name (current-buffer)))
         (proc (get-process proc-name)))
    (ess-view-data-do-kill-buffer-hook ess-view-data-current-backend proc-name proc)))


(define-minor-mode ess-view-data-mode
  "Toggle ess-view-data, a minor mode for browsing R data objects."
  :global nil
  :group 'ess-view-data
  :keymap ess-view-data-mode-map
  :lighter " ESS-V"
  (if ess-view-data-mode
      (progn
        (require 'ansi-color)
        (ansi-color-apply-on-region (point-min) (point-max))
        (setq buffer-read-only t)
        (setq mode-line-process
              '(" ["
                (:eval (format "%d/%d"
                               (1+ ess-view-data-page-number)
                               ess-view-data-total-page))
                (:eval (ess-view-data--mode-line-trace))
                "]"))
        (force-mode-line-update)
        (add-hook 'kill-buffer-hook #'ess-view-data-kill-buffer-hook nil t))))

(defun ess-view-data-print-ex (&optional obj proc-name maxprint)
  "View OBJ in an `ess-view-data' buffer.

Optional argument OBJ the object (data.frame/tibble etc.) to print and view.
Optional argument PROC-NAME the name of associated ESS process.
Optional argument MAXPRINT if non-nil, toggle `ess-view-data-maxprint-p'."
  (interactive "P")
  (let* ((obj (or obj ess-view-data-object))
         (proc-name (or proc-name (buffer-local-value 'ess-local-process-name (current-buffer))))
         (buf (get-buffer-create (format ess-view-data-buffer-name-format obj proc-name)))
         (proc (get-process proc-name))
         command)
    (with-current-buffer buf
      ;; Enable the table major mode up front.  `define-derived-mode'
      ;; runs `kill-all-local-variables' on first activation, which
      ;; would wipe the buffer-local state set below (object, temp
      ;; object, page vars) before `ess-view-data--table-print' gets to
      ;; render.  Turn it on now, while the buffer is still empty, so
      ;; later renders find `derived-mode-p' true and keep the state.
      (when (ess-view-data--display-table-p)
        (ess-view-data-table-mode))
      (if maxprint
          (setq ess-view-data-maxprint-p (not ess-view-data-maxprint-p)))
      (unless ess-view-data-object
        (setq ess-view-data-object obj)
        (setq ess-local-process-name proc-name))
      (ess-view-data--initialize-backend ess-view-data-current-backend proc-name proc)
      (unless (ess-view-data--display-table-p)
        (ess-view-data-get-total-page ess-view-data-current-backend proc-name proc))
      (setq command
            (ess-view-data--do-reset ess-view-data-current-backend
                                    (format "%s" ess-view-data-temp-object))))

    (when (and proc-name proc command (cdr command))
      (ess-view-data--run-r (concat "{" (cdr command) "}") buf nil nil proc)
      (ess-write-to-dribble-buffer "[ESS-v] Print.\n")
      (ess-write-to-dribble-buffer (format "# Trace: %s\n" ess-view-data-history))
      (with-current-buffer buf
        (setq-local scroll-preserve-screen-position t)
        (toggle-truncate-lines 1)
        (if (ess-view-data--display-table-p)
            (ess-view-data--render buf)
          (goto-char (point-min))
          (when ess-view-data-show-code
            (insert (format "# Trace: %s\n" ess-view-data-history)))
          (unless (or ess-view-data-maxprint-p ess-view-data-show-no-page-number)
            (insert (format "# Page number: %d / %d\n"
                            (1+ ess-view-data-page-number)
                            ess-view-data-total-page)))
          (goto-char (point-min))
          (ess-view-data--header-line ess-view-data-current-backend)
          (ess-view-data-mode 1))))
      buf))



;;;###autoload
(defun ess-view-data-print (&optional maxprint)
  "Ess R dv using pprint.
Optional argument MAXPRINT maxprint."
  (interactive "P")
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let* ((obj (or ess-view-data-object
                 (tabulated-list-get-id)
                 (funcall ess-view-data-read-string
                  "Object: "
                  (ess-get-words-from-vector "ls(envir = .GlobalEnv)\n")
                  nil nil (current-word)))))
    (pop-to-buffer (ess-view-data-print-ex obj maxprint))))


(defun ess-view-data-clean-up ()
  "Clean up the temporary objects created by the view process."
  (interactive)
  (unless (and
           ess-local-process-name)
    (error "Not in an R buffer with attached process"))
  (let* ((buf (current-buffer))
         (proc-name (buffer-local-value 'ess-local-process-name buf))
         (proc (get-process proc-name))
         command)
    (setq command (concat "rm("
                          (mapconcat 'identity ess-view-data-temp-object-list
                                      ",")
                           ", envir = globalenv())\n"))
    (when (and proc-name proc command
               (not (process-get proc 'busy)))
      (ess-command (concat "{" command "}") nil nil nil nil proc))
    (setq ess-view-data-temp-object-list (list ess-view-data-temp-object))))


(defun ess-view-data-toggle-maxprint ()
  "Toggle whether to print all rows in one page."
  (interactive)
  (setq ess-view-data-page-number 0)
  (setq ess-view-data-maxprint-p (not ess-view-data-maxprint-p)))

(defun ess-view-data-make-header-line ()
  "Make the header line for the current view buffer."
  (interactive)
  (ess-view-data--header-line ess-view-data-current-backend))


(defun ess-view-data-set-backend (manipulate update summarise write complete)
  "Set backend.

Argument MANIPULATE `ess-view-data-current-backend' from
`ess-view-data-backend-list'.
Argument UPDATE `ess-view-data-current-update-print-backend' from
`ess-view-data-print-backend-list'.
Argument SUMMARISE `ess-view-data-current-summarise-print-backend' from
`ess-view-data-print-backend-list'.
Argument WRITE `ess-view-data-current-save-backend' from
`ess-view-data-save-backend-list'.
Argument COMPLETE `ess-view-data-current-complete-backend' from
`ess-view-data-complete-backend-list'."
  (interactive (list (completing-read
                      (format "Backend for data manipulate (%s): "
                              ess-view-data-current-backend)
				      (mapcar (lambda (x)
						        (symbol-name x))
					          ess-view-data-backend-list)
				      nil t)
                     (completing-read
                      (format "Backend for data print in Emacs buffer (%s): "
                              ess-view-data-current-update-print-backend)
				      (mapcar (lambda (x)
						        (symbol-name x))
					          ess-view-data-print-backend-list)
				      nil t)
                     (completing-read
                      (format "Backend for summary print in Emacs buffer (%s): "
                              ess-view-data-current-summarise-print-backend)
				      (mapcar (lambda (x)
						        (symbol-name x))
					          ess-view-data-print-backend-list)
				      nil t)
                     (completing-read
                      (format "Backend for save data (%s): "
                              ess-view-data-current-save-backend)
				      (mapcar (lambda (x)
						        (symbol-name x))
					          ess-view-data-save-backend-list)
				      nil t)
                     (completing-read
                      (format "Backend for completion (%s): "
                              ess-view-data-current-complete-backend)
				      (mapcar (lambda (x)
						        (symbol-name x))
					          ess-view-data-complete-backend-list)
				      nil t)))
  (unless (or (null manipulate) (string-blank-p manipulate))
    (setq ess-view-data-current-backend (intern manipulate)))
  (unless (or (null update) (string-blank-p update))
    (setq ess-view-data-current-update-print-backend (intern update)))
  (unless (or (null summarise) (string-blank-p summarise))
    (setq ess-view-data-current-summarise-print-backend (intern summarise)))
  (unless (or (null write) (string-blank-p write))
    (setq ess-view-data-current-save-backend (intern write)))
  (unless (or (null complete) (string-blank-p complete))
    (setq ess-view-data-current-complete-backend (intern complete))))



(provide 'ess-view-data)
;;; ess-view-data.el ends here
