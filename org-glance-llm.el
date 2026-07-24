;;; org-glance-llm.el --- LLM sessions for org-glance headlines -*- lexical-binding: t; -*-

;; Author: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; Maintainer: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; URL: https://github.com/rails-to-cosmos/org-glance-llm
;; Version: 0.1.0.0.20260723.0
;; Package-Requires: ((emacs "29.1") (org-glance "1.24") (agnostic-llm "0") (table-view "0"))
;; Keywords: convenience, outlines
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; The `llm' PLUGIN for org-glance: install this package and enable it with
;; (setq org-glance-plugins '(llm)) -- or `I' in the transient.  Core
;; org-glance does not depend on it, so a plain install never pulls in
;; vterm.
;;
;; The `l' action: pick a headline and open the `agnostic-llm' menu pinned to
;; the headline's content-addressable data directory, so the CLI's per-directory
;; context accumulates there.  The `*llm:…*' session buffer is named for the
;; headline's title (see `org-glance-llm--label'); the data dir's hash is the
;; fallback.
;;
;; A headline's session is identified by that data DIR -- a full-hash path
;; unique to the headline, kept as the session buffer's `default-directory'.
;; Reopening the headline switches to the live buffer, so one headline keeps
;; one session; the title label is cosmetic, so two same-titled headlines
;; still get separate sessions.

;;; Code:

(require 'cl-lib)
(require 'table-view)
(require 'org-glance-core)
(require 'org-glance-utils)
(require 'org-glance-graph)
(require 'org-glance-filter)
(require 'org-glance-material)
(require 'org-glance-property-index)
(require 'org-glance-view)

;; `agnostic-llm-menu' is a required dependency, but loaded lazily through its
;; autoload only when the command runs, so org-glance never pulls in vterm at
;; load or byte-compile time.
(declare-function agnostic-llm-menu "agnostic-llm" (&optional root label))

(cl-defun org-glance-llm--slug (title)
  "Downcased dash-separated slug of TITLE, or nil when it has no word chars.
Non-alphanumeric runs become one dash, edges trimmed (\"Buy milk (2L)!\" ->
\"buy-milk-2l\")."
  (let ((slug (string-trim
               (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase (or title "")))
               "-+" "-+")))
    (unless (string-empty-p slug) slug)))

(cl-defun org-glance-llm--buffer-name (label)
  "The `*llm:...*' session buffer name for LABEL."
  (format "*llm:%s*" label))

(cl-defun org-glance-llm--session-buffer? (buf)
  "Non-nil when BUF is a `*llm:…*' session buffer."
  (string-prefix-p "*llm:" (buffer-name buf)))

(cl-defun org-glance-llm--session-buffer (dir)
  "The live agnostic-llm session buffer rooted at DIR, or nil.
DIR is a headline's content-addressable data dir -- a full-hash path unique to
the headline -- so matching a `*llm:…*' buffer's `default-directory' against it
reuses that session, independent of the (cosmetic) title label."
  (cl-find-if (lambda (buf)
                (and (org-glance-llm--session-buffer? buf)
                     (ignore-errors
                       (file-equal-p (buffer-local-value 'default-directory buf)
                                     dir))))
              (buffer-list)))

(cl-defun org-glance-llm--label (metadata dir)
  "The `*llm:...*' label for METADATA's session rooted at DIR.
METADATA's title slug (`--slug'), reading nicer than DIR's content-hash leaf.
Falls back to that leaf when the title slugs to nothing, and appends it to
disambiguate when a session for a DIFFERENT headline already holds the slug."
  (let* ((tail (file-name-nondirectory (directory-file-name dir)))
         (slug (or (org-glance-llm--slug (org-glance-headline-metadata:title metadata))
                   tail))
         (buf (get-buffer (org-glance-llm--buffer-name slug))))
    (if (and buf (not (file-equal-p (buffer-local-value 'default-directory buf)
                                    dir)))
        (format "%s-%s" slug tail)
      slug)))

(cl-defun org-glance-llm--dir (graph id)
  "Session directory for headline ID in GRAPH.
The headline's `ORG_GLANCE_PROJECT_DIR' drawer property when set (a user-chosen
project dir; see `org-glance-material:set-project-dir'), else its
content-addressable data dir."
  (let ((override (org-glance-property-index:property
                   graph id org-glance-project-dir-property)))
    ;; Directory-valued: always trailing-slashed, as `default-directory' expects.
    (file-name-as-directory
     (if (and (stringp override) (not (string-blank-p override)))
         (expand-file-name (string-trim override))
       (org-glance-graph:headline-data-path graph id)))))

;;;###autoload
(cl-defun org-glance-llm ()
  "Choose a headline and open its `agnostic-llm' session.
Prompt for a headline like `org-glance-materialize'.  If that headline's session
buffer is already live, switch to it.  Otherwise materialize the headline and,
from its blob buffer, open `agnostic-llm-menu' with the session directory and
buffer name overridden.  The session directory is the headline's
`ORG_GLANCE_PROJECT_DIR' property when set (see `org-glance-llm--dir'), else its
content-addressable data dir; the label is the title slug
(`org-glance-llm--label').  The menu highlights the override."
  (interactive)
  (org-glance-ensure-init)
  (org-glance-llm--open-session org-glance-graph
                                (org-glance-material:pick-metadata org-glance-graph)))

(cl-defun org-glance-llm--open-session (graph metadata)
  "Open (or switch to) METADATA's `agnostic-llm' session in GRAPH."
  (let* ((id (org-glance-headline-metadata:id metadata))
         (dir (org-glance-llm--dir graph id))
         (label (org-glance-llm--label metadata dir))
         (existing (org-glance-llm--session-buffer dir)))
    (if (buffer-live-p existing)
        (switch-to-buffer existing)
      (make-directory dir t)
      ;; Materialize the headline, then launch the menu pinned to DIR (its
      ;; project dir, or the data dir) as the session root.
      (switch-to-buffer (org-glance-material:open graph id))
      (agnostic-llm-menu dir label))))

(cl-defun org-glance-llm-here ()
  "Open THIS materialized headline's LLM session (`C-c l').
The transient's `l', scoped to the buffer at hand."
  (interactive)
  (pcase-let ((`(,graph . ,id) (org-glance-material:current)))
    (org-glance-llm--open-session graph (org-glance-graph:get-headline graph id))))

;;; Sessions table (`L' in the transient)
;;
;; One row per LLM session -- a state machine over its lifetime: `running'
;; (live buffer, live process), `exited' (live buffer, dead process), and
;; `stopped' (no buffer, but the provider recorded a transcript).  Rows come
;; from two CHEAP live sources, never a full-graph scan: the provider's
;; recorded session store, filtered to THIS graph's data dirs
;; (`--recorded', O(recorded) -- a handful, not the thousands of headlines),
;; for the historical `stopped' rows; overlaid with live `*llm:…*' buffers
;; for running/exited state.  A recorded leaf name decodes straight back to
;; its headline id (`--decode-id'), so titles and `m' work without probing a
;; single extra headline.  Nothing is persisted -- state is always current,
;; and there is no cache to go stale (invariant 23).  Like the entry command,
;; `agnostic-llm' (and thus vterm) loads lazily at run time.

(declare-function agnostic-llm "agnostic-llm" (&optional user-root label))
(declare-function agnostic-llm--provider-get "agnostic-llm" (key))
(declare-function agnostic-llm--session-file "agnostic-llm" (dir))
(declare-function agnostic-llm--prompt-history-files "agnostic-llm" (&optional root))
(declare-function agnostic-llm--prompt-preview "agnostic-llm" (file))
(defvar agnostic-llm--root-override)

(cl-defun org-glance-llm--buffer-label (buf)
  "LABEL of BUF's `*llm:LABEL*' name (uniquifying `<N>' suffix dropped)."
  (let ((name (buffer-name buf)))
    (if (string-match "\\`\\*llm:\\(.*?\\)\\*\\(<[0-9]+>\\)?\\'" name)
        (match-string 1 name)
      name)))

(cl-defun org-glance-llm--buffer-dir (buf)
  "BUF's session root: its `agnostic-llm--root-override', else its
`default-directory', as a directory name."
  (file-name-as-directory
   (expand-file-name
    (or (and (local-variable-p 'agnostic-llm--root-override buf)
             (buffer-local-value 'agnostic-llm--root-override buf))
        (buffer-local-value 'default-directory buf)))))

(cl-defun org-glance-llm--live-buffers ()
  "Every live `*llm:…*' session buffer."
  (cl-remove-if-not #'org-glance-llm--session-buffer? (buffer-list)))

(cl-defun org-glance-llm--state (buf)
  "Session state for BUF (nil = no buffer): running / exited / stopped."
  (let ((proc (and buf (get-buffer-process buf))))
    (cond ((null buf) "stopped")
          ((and proc (process-live-p proc)) "running")
          (t "exited"))))

(cl-defun org-glance-llm--last-prompt (dir)
  "One-line preview of DIR's newest saved prompt, or nil."
  (when-let ((file (car (agnostic-llm--prompt-history-files dir))))
    (agnostic-llm--prompt-preview file)))

(cl-defun org-glance-llm--last (transcript)
  "TRANSCRIPT file's mtime as the table's Last cell, or \"\" when nil."
  (if transcript
      (format-time-string "%Y-%m-%d %H:%M"
                          (file-attribute-modification-time
                           (file-attributes transcript)))
    ""))

(cl-defun org-glance-llm--data-store-prefix (graph)
  "Provider-name prefix (trailing `-') for GRAPH's headline data dirs.
A recorded session leaf under `agnostic-llm--session-dir' begins with this
exactly when its dir is a headline data dir in GRAPH; the tail is that
headline's id as `SHARD-REST', the `/' between shard and rest flattened.
Encodes GRAPH's data path the same way -- `/' and `.' to `-'."
  (concat (replace-regexp-in-string
           "[/.]" "-"
           (directory-file-name
            (expand-file-name (org-glance-graph:data-path graph))))
          "-"))

(cl-defun org-glance-llm--decode-id (name prefix)
  "Headline id encoded in recorded session leaf NAME, or nil.
Non-nil only when NAME begins with PREFIX (this graph's data store,
`--data-store-prefix').  The remainder is the id as `org-glance-graph:headline-
data-path' laid it out: a short id (<=2 chars, unsharded) is the tail itself;
a longer one is a 2-char SHARD, a `-' (the flattened data-path `/'), then REST,
rejoined here.  An id holding a literal `.' decodes wrong and drops out at the
caller's `get-headline' check."
  (when (string-prefix-p prefix name)
    (let ((tail (substring name (length prefix))))
      (cond ((zerop (length tail)) nil)
            ((<= (length tail) 2) tail)
            ((eq (aref tail 2) ?-) (concat (substring tail 0 2) (substring tail 3)))))))

(cl-defun org-glance-llm--recorded (graph)
  "Recorded sessions for GRAPH as `(DIR ID META)' triples; O(recorded).
Lists the provider's session store, keeps the leaves under GRAPH's data
store (`--data-store-prefix'), and decodes each to its headline id and live
metadata.  No headline scan -- only the handful of dirs with a transcript
are touched, so this stays cheap however large the graph."
  (let* ((store (agnostic-llm--provider-get :session-dir))
         (prefix (org-glance-llm--data-store-prefix graph))
         result)
    (when (file-directory-p store)
      (dolist (name (directory-files store nil
                                     directory-files-no-dot-files-regexp t))
        (when-let* ((id (org-glance-llm--decode-id name prefix))
                    (meta (org-glance-graph:get-headline graph id))
                    ((org-glance-headline-metadata? meta)))
          (push (list (org-glance-llm--dir graph id) id meta) result))))
    (nreverse result)))

(cl-defun org-glance-llm--row-for (dir id title buf)
  "Table row for the session at DIR (headline ID, may be nil) titled TITLE.
State and buffer name come from live BUF (or nil); `last' and `prompt' read
DIR's provider transcript and saved prompts.  The single row builder --
recorded and orphan-live sessions both route through it."
  `((id . ,dir)
    (headline . ,id)
    (cells . ((title . ,(or title ""))
              (state . ,(org-glance-llm--state buf))
              (buffer . ,(if buf (buffer-name buf) ""))
              (last . ,(org-glance-llm--last (agnostic-llm--session-file dir)))
              (prompt . ,(if-let ((p (org-glance-llm--last-prompt dir)))
                             (truncate-string-to-width p 48 nil nil "…")
                           ""))
              (dir . ,(abbreviate-file-name dir))))))

(cl-defun org-glance-llm--session-rows (graph)
  "Rows for the sessions table, from two cheap live sources.
GRAPH's recorded sessions (`--recorded', O(recorded)) give the historical
`stopped' rows and their titles; live `*llm:…*' buffers overlay
running/exited state and add any session missing from the store (a fresh
one, or one owned by no headline).  No full-headline scan, no persisted
cache -- the table is always current."
  (let ((buf-by-dir (make-hash-table :test 'equal))
        rows)
    (dolist (buf (org-glance-llm--live-buffers))
      (puthash (org-glance-llm--buffer-dir buf) buf buf-by-dir))
    (dolist (rec (org-glance-llm--recorded graph))
      (pcase-let ((`(,dir ,id ,meta) rec))
        (let ((buf (gethash dir buf-by-dir)))
          (remhash dir buf-by-dir)
          (push (org-glance-llm--row-for
                 dir id (org-glance-headline-metadata:title meta) buf)
                rows))))
    (maphash (lambda (dir buf)
               (push (org-glance-llm--row-for
                      dir nil (org-glance-llm--buffer-label buf) buf)
                     rows))
             buf-by-dir)
    (nreverse rows)))

(defconst org-glance-llm--sessions-spec
  '((title . "org-glance llm sessions")
    (columns . (((key . "state")  (header . "State")  (type . "badge") (sortable . t) (align . "left")
                 (badges . (((value . "running") (color . "#9ece6a"))
                            ((value . "exited")  (color . "#e0af68"))
                            ((value . "stopped") (color . "#565f89")))))
                ((key . "title")  (header . "Title")  (type . "text") (sortable . t) (align . "left"))
                ((key . "buffer") (header . "Buffer") (type . "text") (sortable . t) (align . "left"))
                ((key . "last")   (header . "Last")   (type . "text") (sortable . t) (align . "left"))
                ((key . "prompt") (header . "Prompt") (type . "text") (sortable . nil) (align . "left"))
                ((key . "dir")    (header . "Dir")    (type . "text") (sortable . t) (align . "left"))))
    (actions . (((key . "RET") (command . "open")        (label . "Open"))
                ((key . "m")   (command . "materialize") (label . "Materialize"))
                ((key . "k")   (command . "kill")        (label . "Kill"))
                ((key . "g")   (command . "refresh")     (label . "Refresh"))))
    (sort . ((column . "state") (ascending . t))))
  "The `table-view' spec for the LLM sessions table.
A constant: it depends on no graph state,
and `table-view-display' never mutates a passed spec.")

(cl-defun org-glance-llm--act-open (graph dir row)
  "Pop to DIR's running session; else (re)start it, continuing its transcript.
The label: the owning headline's title slug, else the old buffer's label,
else DIR's leaf."
  (let ((buf (org-glance-llm--session-buffer dir)))
    (if (and (buffer-live-p buf)
             (process-live-p (get-buffer-process buf)))
        (pop-to-buffer buf)
      (let* ((id (alist-get 'headline row))
             (meta (and id (org-glance-graph:get-headline graph id)))
             (label (cond ((org-glance-headline-metadata? meta)
                           (org-glance-llm--label meta dir))
                          (buf (org-glance-llm--buffer-label buf))
                          (t (file-name-nondirectory (directory-file-name dir))))))
        (agnostic-llm dir label)))))

(cl-defun org-glance-llm--act-kill (dir)
  "Kill DIR's live session buffer, after confirming."
  (let ((buf (org-glance-llm--session-buffer dir)))
    (cond ((not (buffer-live-p buf)) (user-error "No live session buffer"))
          ((y-or-n-p (format "Kill %s? " (buffer-name buf)))
           (let ((kill-buffer-query-functions nil))
             (kill-buffer buf))
           (table-view-refresh (current-buffer))
           (table-view-apply-sort)))))

(cl-defun org-glance-llm--act-materialize (graph row)
  "Materialize the row's owning headline."
  (let ((id (alist-get 'headline row)))
    (unless id (user-error "This session belongs to no headline"))
    (switch-to-buffer (org-glance-material:open graph id))))

(cl-defun org-glance-llm-sessions:visit (graph)
  "Open GRAPH's LLM sessions table, enumerated live from the provider store.
`g' re-reads the store and live buffers."
  (let* ((fill-fn (lambda (buf)
                    (with-current-buffer buf
                      (table-view-set-rows
                       buf (org-glance-llm--session-rows graph)))))
         (handlers (list (cons "open" (lambda (id row) (org-glance-llm--act-open graph id row)))
                         (cons "materialize" (lambda (_id row) (org-glance-llm--act-materialize graph row)))
                         (cons "kill" (lambda (id _row) (org-glance-llm--act-kill id)))
                         (cons "refresh"
                               (lambda (_id _row)
                                 ;; Keep point on the same CELL, like the
                                 ;; headline table's `g' (invariant 24).
                                 (pcase-let ((`(,id ,line ,col)
                                              (org-glance-view:point-context)))
                                   (table-view-set-rows
                                    (current-buffer)
                                    (org-glance-llm--session-rows graph))
                                   (table-view-apply-sort)
                                   (org-glance-view:restore-point id line col)))))))
    (org-glance-view:display-table graph "*org-glance-llm-sessions*"
                                   org-glance-llm--sessions-spec handlers fill-fn)))

;;;###autoload
(cl-defun org-glance-llm-sessions ()
  "Table of every LLM session, running, exited, or stopped -- instantly.
History comes from the provider's recorded session store (this graph's
sessions only), overlaid live with running/exited state and any buffer
started since; `g' re-reads.  No full-graph scan, so it opens instantly
however large the graph.  RET pops to a running session or (re)starts a
stopped one; `m' materializes the owning headline; `k' kills a live buffer.
Loads `agnostic-llm' (and vterm) lazily, like `org-glance-llm'."
  (interactive)
  (org-glance-ensure-init)
  (require 'agnostic-llm)
  (org-glance-llm-sessions:visit org-glance-graph))

;; Plugin self-registration: `C-c l' in material buffers (the core freed it;
;; history is `C-c h') opens THIS headline's session.
(define-key org-glance-material-mode-map (kbd "C-c l") #'org-glance-llm-here)

;; Plugin self-registration: the core transient hardcodes no plugin keys;
;; this plugin appends its own `l' / `L' row after the Actions group.
;; Remove-then-append keeps a reload from duplicating the row.
(with-eval-after-load 'org-glance-ui
  (ignore-errors (transient-remove-suffix 'org-glance-transient "l"))
  (ignore-errors (transient-remove-suffix 'org-glance-transient "L"))
  (transient-append-suffix 'org-glance-transient '(2)
    [:class transient-row
     ("l" "LLM session" org-glance-llm)
     ("L" "LLM sessions" org-glance-llm-sessions)]))

(provide 'org-glance-llm)
;;; org-glance-llm.el ends here
