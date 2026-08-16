;;; ess-view-data-backend.el --- Backends of ess-view-data    -*- lexical-binding: t; -*-

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

;; Backend implementations of ess-view-data: the verb code-generation
;; table and shared command builders, the page-data protocol and the
;; edit-indirect buffer templates, the print/kable print backends, the
;; dplyr / dplyr+DT / data.table+magrittr data backends and the save
;; backend.  Depends only on ess-view-data-core.

;;; Code:

(require 'ess-view-data-core)
(require 'ess-inf)
(require 'ess-r-mode)

;; `ess-view-data-edit-mode' is defined in the main entry file (only
;; upward reference of this file); declared here for byte-compilation.
(declare-function ess-view-data-edit-mode "ess-view-data.el")

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

(provide 'ess-view-data-backend)

;;; ess-view-data-backend.el ends here
