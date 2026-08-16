;;; ess-view-data-core.el --- Shared core of ess-view-data    -*- lexical-binding: t; -*-

;; Copyright (C) 2019-2026  Shuguang Sun <shuguang79@qq.com>

;; Author: Shuguang Sun <shuguang79@qq.com>
;; Created: 2019/04/06
;; Version: 1.5
;; URL: https://github.com/ShuguangSun/ess-view-data
;; Package-Requires: ((emacs "26.1") (ess "18.10.1") (csv-mode "1.12") (transient "0.3.7"))
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

;; Shared foundation of ess-view-data: customization group, options and
;; buffer-local state, pure utilities, and the generic backend API.
;; Sub-feature files (backend, table, complete) depend on this file
;; only, so that the require graph stays acyclic.

;;; Code:

(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'cl-generic))

(require 'cl-lib)
(require 'cl-generic)
(require 'ess-inf)

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

(defcustom ess-view-data-auto-show-transient nil
  "Whether to automatically show the transient menu when opening an ess-view-data buffer."
  :type 'boolean
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

(defun ess-view-data--invalidate-completion (buf)
  "Drop the completion and column caches of the view buffer BUF.
Called after any verb that changes the temp object so stale
candidates are never offered (C3)."
  (with-current-buffer buf
    (setq ess-view-data-completion-candidate nil)
    (setq ess-view-data--page-cols nil)
    (setq ess-view-data--table-rows nil)
    (setq ess-view-data--table-types nil)))

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

(provide 'ess-view-data-core)

;;; ess-view-data-core.el ends here
