;;; ess-view-data-complete.el --- Completion of ess-view-data    -*- lexical-binding: t; -*-

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

;; The completion support of ess-view-data: the per-buffer completion
;; cache (object columns and per-column values), the jsonlite
;; do-complete-data method and the interactive completion commands
;; used inside edit-indirect buffers.  Depends only on
;; ess-view-data-core.

;;; Code:

(require 'ess-view-data-core)
(require 'ess-r-completion)
(require 'json)

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

(provide 'ess-view-data-complete)

;;; ess-view-data-complete.el ends here
