;;; ess-view-data.el --- View Data                   -*- lexical-binding: t; -*-

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

;; This file is the entry point of the ess-view-data package.  The
;; implementation is split across four support files, all loaded by
;; requiring this one:
;; - ess-view-data-core.el: customization group, options and
;;   buffer-local state, pure utilities and the generic backend API.
;; - ess-view-data-backend.el: verb code generation, the shared
;;   backend skeleton and the dplyr / dplyr+DT / data.table+magrittr
;;   data backends plus the print/kable and save backends.
;; - ess-view-data-table.el: the tabulated-list table display,
;;   server-side sorting, cell widening and the render/refresh
;;   orchestration.
;; - ess-view-data-complete.el: completion cache and commands.
;;
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
;;
;; The header line follows horizontal scrolling: it is rebuilt before every
;; redisplay from the window's current horizontal scroll, so column names stay
;; aligned with the data at any scroll position and the columns hidden right of
;; the window become reachable by scrolling right (also after `a').

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
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'ess-view-data-core)
(require 'ess-view-data-backend)
(require 'ess-view-data-table)
(require 'ess-view-data-complete)

;;; * Mode map, transient menu and edit mode

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
    (define-key keymap (kbd "?") #'ess-view-data-transient)
    keymap)
  "Keymap for function `ess-view-data-mode'.")

(transient-define-prefix ess-view-data-transient ()
  "ESS View Data commands."
  [["Navigation"
   ("n" "Next page" ess-view-data-goto-next-page)
   ("p" "Previous page" ess-view-data-goto-previous-page)
   ("F" "First page" ess-view-data-goto-first-page)
   ("l" "Last page" ess-view-data-goto-last-page)
   ("g" "Goto page" ess-view-data-goto-page-number)]
  ["View"
   ("t" "Toggle maxprint" ess-view-data-toggle-maxprint)
   ("P" "Print" ess-view-data-print-ex)]
  ["Data Manipulation"
   ("s" "Select columns" ess-view-data-select)
   ("u" "Unselect columns" ess-view-data-unselect)
   ("f" "Filter rows" ess-view-data-filter)
   ("o" "Sort" ess-view-data-sort)
   ("i" "Slice" ess-view-data-slice)
   ("m" "Mutate" ess-view-data-mutate)
   ("<tab>" "Long to wide (pivot_wider)" ess-view-data-long2wide-pivot-wider)
   ("C-<tab>" "Wide to long (pivot_longer)" ess-view-data-wide2long-pivot-longer)]
  ["Summarize"
   ("c" "Count" ess-view-data-count)
   ("U" "Unique" ess-view-data-unique)
   ("v" "Summarise" ess-view-data-summarise)
   ("S" "Skimr" ess-view-data-skimr)]
  ["Other"
   ("V" "Any data manipulation verb" ess-view-data-verbs)
   ("r" "Reset" ess-view-data-reset)
   ("w" "Save to csv file" ess-view-data-save)
   ("q" "Quit" ess-view-data-quit)]])

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

;; wide2long
(defun ess-view-data-wide2long-pivot-longer ()
  "Do wide2long using 'pivot_longer'."
  (interactive)
  (ess-view-data-do-apply 'update 'wide2long-pivot_longer t nil t))

;; long2wide
(defun ess-view-data-long2wide ()
  "Do long2wide."
  (interactive)
  (ess-view-data-do-apply 'update 'long2wide t nil t))

;; long2wide - Pivot_wider
(defun ess-view-data-long2wide-pivot-wider ()
  "Do long2wide using 'pivot_wider'."
  (interactive)
  (ess-view-data-do-apply 'update 'long2wide-pivot_wider t nil t))

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
        (add-hook 'kill-buffer-hook #'ess-view-data-kill-buffer-hook nil t)
        (when ess-view-data-auto-show-transient
          (ess-view-data-transient)))))

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
                  (ess-get-words-from-vector "Filter(function(x) inherits(get(x, envir = .GlobalEnv), 'data.frame'), c(ls(envir = .GlobalEnv), '.Last.value'))\n")
                  nil nil nil nil (current-word)))))
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
