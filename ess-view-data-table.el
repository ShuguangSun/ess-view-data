;;; ess-view-data-table.el --- Table display of ess-view-data    -*- lexical-binding: t; -*-

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

;; The table display of ess-view-data: page-data protocol parser,
;; tabulated-list rendering with scrolling header, server-side header
;; sort, cell value inspection and column widening, the table major
;; mode and the shared render/refresh orchestration.  Depends on
;; ess-view-data-core and ess-view-data-backend.

;;; Code:

(require 'ess-view-data-core)
(require 'ess-view-data-backend)
(require 'tabulated-list)

;; `ess-view-data-mode' is defined in the main entry file (only upward
;; reference of this file); declared here for byte-compilation.
(declare-function ess-view-data-mode "ess-view-data.el")

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

;;; ** Scrolling table header

;; The stock `tabulated-list-init-header' builds a static header whose
;; labels are pinned to the left edge of the window text area with
;; `:align-to'.  Horizontal scrolling moves the body but not the
;; header, so the two drift apart as soon as the table is wider than
;; the window.  The dynamic header below is rebuilt before every
;; redisplay (via a buffer-local `pre-redisplay-functions' hook, the
;; same mechanism Emacs uses for `header-line-indent-mode') from the
;; window's current horizontal scroll: each label is placed at its
;; buffer column minus the scroll, labels outside the viewport are
;; omitted and a partially visible label is sliced to its visible part.

(defun ess-view-data--table-sort-indicator (desc)
  "Sort indicator character for the table header, DESC for descending.
Uses the same characters as `tabulated-list-init-header'; on Emacs
26.1, where the customization variables are absent, falls back to the
default arrow glyphs."
  (if desc
      (if (boundp 'tabulated-list-gui-sort-indicator-desc)
          tabulated-list-gui-sort-indicator-desc
        ?▲)
    (if (boundp 'tabulated-list-gui-sort-indicator-asc)
        tabulated-list-gui-sort-indicator-asc
      ?▼)))

(defun ess-view-data--table-header-string (fmt hscroll win-width
                                               &optional indent-width)
  "Table header line string for `tabulated-list-format' FMT.

The labels are laid out like `tabulated-list-init-header' does, but
relative to the window viewport [HSCROLL, HSCROLL+WIN-WIDTH): every
label is placed at its buffer column minus HSCROLL, labels outside the
viewport are omitted and a partially visible label is sliced to its
visible part, so the header stays aligned with the body when the
window is horizontally scrolled.  INDENT-WIDTH (default 0) is added
to each `:align-to' offset; pass `header-line-indent-width' on Emacs
29+ so the header also lines up with display line numbers.

`tabulated-list-sort-key' (sort indicator) and `tabulated-list-padding'
are read from the current buffer."
  (let* ((len (length fmt))
         (x (max tabulated-list-padding 0))
         (hscroll (floor hscroll))
         (right-edge (+ hscroll (floor win-width)))
         (indent (or indent-width 0))
         (cols nil)
         (button-props (list 'help-echo "Click to sort by column"
                             'mouse-face 'header-line-highlight
                             'keymap tabulated-list-sort-button-map)))
    (dotimes (n len)
      (let* ((col (aref fmt n))
             (not-last-col (< n (1- len)))
             (label (nth 0 col))
             (pname label)
             (orig-lablen (string-width label))
             (width (nth 1 col))
             (props (nthcdr 3 col))
             (pad-right (or (plist-get props :pad-right) 1))
             (right-align (plist-get props :right-align))
             (next-x (+ x pad-right width))
             (available-space
              (and not-last-col
                   (if right-align
                       width
                     (let* ((next-col (aref fmt (1+ n)))
                            (next-right (plist-get (nthcdr 3 next-col)
                                                   :right-align))
                            (next-width (nth 1 next-col)))
                       (if next-right
                           (- (+ width next-width)
                              (min next-width (string-width (car next-col))))
                         width))))))
        ;; Truncate the label exactly like `tabulated-list-init-header'.
        (when (and (>= orig-lablen 3)
                   not-last-col
                   (> orig-lablen available-space))
          (setq label (truncate-string-to-width label available-space nil nil t)))
        ;; Append the sort indicator for the sorted column.
        (when (and (nth 2 col)
                   (equal (car col) (car tabulated-list-sort-key)))
          (unless (and (< orig-lablen 3) not-last-col)
            (setq label (concat label
                                (format " %c"
                                        (ess-view-data--table-sort-indicator
                                         (cdr tabulated-list-sort-key)))))))
        ;; Slice the label region [L0, L1) against the viewport.
        (let* ((sw (string-width label))
               (l0 (if right-align (max x (- (+ x width) sw)) x))
               (l1 (if right-align (max (+ x width) (+ x sw)) (+ x sw)))
               (v0 (max l0 hscroll))
               (v1 (min l1 right-edge)))
          (when (< v0 v1)
            (let* ((slice-start (- v0 l0))
                   (slice-width (- v1 v0))
                   (text (if (and (= slice-start 0) (= slice-width sw))
                              label
                            (truncate-string-to-width label
                                                      (+ slice-start slice-width)
                                                      slice-start)))
                   (text (cond
                          ((not (nth 2 col))
                           (propertize text 'tabulated-list-column-name pname))
                          ((equal (car col) (car tabulated-list-sort-key))
                           (apply #'propertize text
                                  'face 'bold
                                  'tabulated-list-column-name pname
                                  button-props))
                          (t
                           (apply #'propertize text
                                  'tabulated-list-column-name pname
                                  button-props)))))
              (push (concat
                     (propertize " " 'display
                                 `(space :align-to (+ ,indent ,(- v0 hscroll))))
                     text)
                    cols))
            ;; Gap before the next column, when the next label is visible.
            (when (and not-last-col (>= pad-right 0) (< next-x right-edge))
              (push (propertize " " 'display
                                `(space :align-to (+ ,indent ,(- next-x hscroll)))
                                'face 'fixed-pitch)
                    cols))))
        (setq x next-x)))
    (apply 'concat (nreverse cols))))

(defun ess-view-data--table-header-refresh (window)
  "Rebuild `header-line-format' for WINDOW from its horizontal scroll.
The label positions follow the window viewport, so the header stays
aligned with the body under horizontal scrolling.  Reads
`tabulated-list-format' and the sort key from the current buffer,
which is the buffer displayed in WINDOW."
  (let* ((indent (and (boundp 'header-line-indent-width) header-line-indent-width))
         (header (ess-view-data--table-header-string
                  tabulated-list-format
                  (window-hscroll window)
                  (window-width window)
                  indent)))
    (if indent
        (setq header-line-format (list "" 'header-line-indent header))
      (setq header-line-format (list "" header)))))

(defun ess-view-data--table-header-format (window)
  "Rebuild the table header for WINDOW before each redisplay.
Installed buffer-locally on `pre-redisplay-functions', it keeps the
header aligned with the body for every horizontal scroll entry point,
such as commands, the mouse wheel, scroll bars and auto-hscroll.
`current-buffer' is the buffer displayed in WINDOW.  Does nothing
outside an `ess-view-data-table-mode' buffer with a current table
format, so other tabulated-list modes keep their static header."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (ess-view-data--display-table-p)
             (derived-mode-p 'ess-view-data-table-mode)
             tabulated-list-format
             tabulated-list-use-header-line)
    (ess-view-data--table-header-refresh window)))

(defun ess-view-data--table-header-install ()
  "Install the scrolling-aware table header in the current buffer.
Adds a buffer-local `pre-redisplay-functions' hook (the single
`pre-redisplay-function' on Emacs 26.1) that rebuilds
`header-line-format' before each redisplay.  Called from
`ess-view-data--table-header-after-init', i.e. only in
`ess-view-data-table-mode' buffers."
  (if (boundp 'pre-redisplay-functions)
      (add-hook 'pre-redisplay-functions
                #'ess-view-data--table-header-format nil t)
    (setq-local pre-redisplay-function
                (lambda (&rest _)
                  (ess-view-data--table-header-format (selected-window))))))

(defun ess-view-data--table-header-after-init (&rest _)
  "Install the scrolling table header after `tabulated-list-init-header'.
Only `ess-view-data-table-mode' buffers with a current
`tabulated-list-format' are affected; other tabulated-list buffers,
such as package-menu and ibuffer, keep the static header."
  (when (and (ess-view-data--display-table-p)
             (derived-mode-p 'ess-view-data-table-mode)
             tabulated-list-format)
    (ess-view-data--table-header-install)
    (let ((window (get-buffer-window (current-buffer) t)))
      (when (window-live-p window)
        (ess-view-data--table-header-refresh window)))))

(when (fboundp 'tabulated-list-init-header)
  (advice-add 'tabulated-list-init-header :after
              #'ess-view-data--table-header-after-init))

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

(provide 'ess-view-data-table)

;;; ess-view-data-table.el ends here
