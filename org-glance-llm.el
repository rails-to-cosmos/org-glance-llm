;;; org-glance-llm.el --- LLM sessions for org-glance headlines -*- lexical-binding: t; -*-

;; Author: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; Maintainer: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; URL: https://github.com/rails-to-cosmos/org-glance-llm
;; Version: 0.5.1.0.20261025.0
;; Package-Requires: ((emacs "29.1") (org-glance "1.24") (agnostic-llm "20261025") (table-view "0"))
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
;; context accumulates there.  The menu selects the provider first; its model
;; choices then come from that provider's catalog.  The `*llm:…*' session
;; buffer is named for the headline's title (see `org-glance-llm--label'); the
;; data dir's hash is the fallback.
;;
;; A session is identified by provider, data DIR, and canonical name.  Its data
;; dir remains the buffer's `default-directory'; named conversations coexist
;; under one headline.

;;; Code:

(require 'cl-lib)
(require 'table-view)
(require 'org-glance-core)
(require 'org-glance-graph)
(require 'org-glance-material)
(require 'org-glance-property-index)
(require 'org-glance-view)

;; `agnostic-llm-menu' is a required dependency, but loaded lazily through its
;; autoload only when the command runs, so org-glance never pulls in vterm at
;; load or byte-compile time.
(declare-function agnostic-llm-menu "agnostic-llm" (&optional root label))
(declare-function agnostic-llm-set-provider "agnostic-llm" (provider))
(defvar agnostic-llm-provider 'claude)
(defvar agnostic-llm-session-name nil)

(cl-defun org-glance-llm--provider-description ()
  "Describe the provider choice like the menu's model option."
  (format "Provider [%s]" agnostic-llm-provider))

(transient-define-suffix org-glance-llm--menu-set-provider ()
  "Choose the provider, refresh its model choices, and keep the LLM menu open."
  :description #'org-glance-llm--provider-description
  :transient t
  (interactive)
  (call-interactively #'agnostic-llm-set-provider)
  ;; A model or effort selected before the provider changed belongs to the old
  ;; catalog.  Clear both live infixes; the redisplay reads the new catalog.
  (dolist (command '(agnostic-llm--menu-model-option
                     agnostic-llm--menu-effort-option))
    (when-let* ((infix (transient-suffix-object command)))
      (transient-infix-set infix nil))))

(cl-defun org-glance-llm--install-provider-option ()
  "Place the provider choice beside model in `agnostic-llm-menu'."
  (when (ignore-errors (transient-get-suffix 'agnostic-llm-menu "B"))
    (transient-remove-suffix 'agnostic-llm-menu "B"))
  (when (ignore-errors (transient-get-suffix 'agnostic-llm-menu "-p"))
    (transient-remove-suffix 'agnostic-llm-menu "-p"))
  (transient-insert-suffix 'agnostic-llm-menu "-m"
    '("-p" org-glance-llm--menu-set-provider)))

(with-eval-after-load 'agnostic-llm
  (org-glance-llm--install-provider-option))

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

(cl-defun org-glance-llm--session-buffer
    (dir &key (provider agnostic-llm-provider) session-name)
  "The live PROVIDER SESSION-NAME buffer rooted at DIR, or nil.
DIR is a headline's content-addressable data dir -- a full-hash path unique to
the headline -- so matching a `*llm:…*' buffer's `default-directory' against it
reuses that session, independent of the title label.  PROVIDER and SESSION-NAME
complete the identity."
  (cl-find-if (lambda (buf)
                (and (org-glance-llm--session-buffer? buf)
                     (eq (buffer-local-value 'agnostic-llm-provider buf) provider)
                     (equal (buffer-local-value 'agnostic-llm-session-name buf)
                            session-name)
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
content-addressable data dir.  Its label is the title slug from
`org-glance-llm--label'.  The menu highlights the override."
  (interactive)
  (org-glance-ensure-init)
  (org-glance-llm--open-session org-glance-graph
                                (org-glance-material:pick-metadata org-glance-graph)))

(cl-defun org-glance-llm--open-session (graph metadata)
  "Open METADATA's named-session menu in GRAPH."
  (let* ((id (org-glance-headline-metadata:id metadata))
         (dir (org-glance-llm--dir graph id))
         (label (org-glance-llm--label metadata dir)))
    (make-directory dir t)
    (switch-to-buffer (org-glance-material:open graph id))
    (agnostic-llm-menu dir label)))

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

(declare-function agnostic-llm "agnostic-llm" (&optional user-root label session-name))
(declare-function agnostic-llm--provider-get "agnostic-llm" (key))
(declare-function agnostic-llm--session-file "agnostic-llm" (dir))
(declare-function agnostic-llm--codex-session-meta "agnostic-llm" (file))
(declare-function agnostic-llm--codex-session-id "agnostic-llm" (file))
(declare-function agnostic-llm--codex-name-index "agnostic-llm" ())
(declare-function agnostic-llm--named-sessions "agnostic-llm" (root))
(declare-function agnostic-llm--prompt-history-files "agnostic-llm" (&optional root))
(declare-function agnostic-llm--prompt-preview "agnostic-llm" (file))
(defvar agnostic-llm--root-override)
(defvar agnostic-llm-session-label)

(cl-defun org-glance-llm--role-from-provider-name (name)
  "Return the role slug encoded in provider session NAME, or nil."
  (and name (string-match "--\\([^-].*\\)\\'" name)
       (match-string 1 name)))

(cl-defun org-glance-llm--buffer-label (buf)
  "LABEL of BUF's `*llm:LABEL*' name (uniquifying `<N>' suffix dropped)."
  (let ((name (buffer-name buf)))
    (if (string-match "\\`\\*llm:\\(.*?\\)\\*\\(<[0-9]+>\\)?\\'" name)
        (match-string 1 name)
      name)))

(cl-defun org-glance-llm--buffer-dir (buf)
  "Return BUF's session root as a directory name.
Use its `agnostic-llm--root-override', then its `default-directory'."
  (file-name-as-directory
   (expand-file-name
    (or (and (local-variable-p 'agnostic-llm--root-override buf)
             (buffer-local-value 'agnostic-llm--root-override buf))
        (buffer-local-value 'default-directory buf)))))

(cl-defun org-glance-llm--live-buffers (&optional (provider agnostic-llm-provider))
  "Every live PROVIDER `*llm:…*' session buffer."
  (cl-remove-if-not
   (lambda (buf)
     (and (org-glance-llm--session-buffer? buf)
          (eq (buffer-local-value 'agnostic-llm-provider buf) provider)))
   (buffer-list)))

(cl-defun org-glance-llm--state (buf)
  "Session state for BUF (nil = no buffer): running / exited / stopped."
  (let ((proc (and buf (get-buffer-process buf))))
    (cond ((null buf) "stopped")
          ((and proc (process-live-p proc)) "running")
          (t "exited"))))

(cl-defun org-glance-llm--last-prompt (dir)
  "One-line preview of DIR's newest saved prompt, or nil."
  (when-let* ((file (car (agnostic-llm--prompt-history-files dir))))
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

(cl-defun org-glance-llm--recorded-encoded (graph)
  "Directory-encoded provider sessions for GRAPH.
Each record is `(DIR ID META ROLE PROVIDER-NAME TRANSCRIPT)'."
  (let* ((store (agnostic-llm--provider-get :session-dir))
         (prefix (org-glance-llm--data-store-prefix graph))
         result)
    (when (file-directory-p store)
      (dolist (name (directory-files store nil
                                     directory-files-no-dot-files-regexp t))
        (when-let* ((id (org-glance-llm--decode-id name prefix))
                    (meta (org-glance-graph:get-headline graph id))
                    ((org-glance-headline-metadata? meta)))
          (let* ((dir (org-glance-llm--dir graph id))
                 (provider-dir (expand-file-name name store))
                 (named (agnostic-llm--named-sessions dir))
                 (files (directory-files provider-dir t "\\.jsonl\\'" t))
                 (named-files (mapcar #'caddr named)))
            (when (cl-some (lambda (file) (not (member file named-files))) files)
              (push (list dir id meta nil nil
                          (car (sort (cl-set-difference files named-files
                                                        :test #'equal)
                                     #'file-newer-than-file-p)))
                    result))
            (dolist (session named)
              (pcase-let ((`(,provider-name ,_selector ,file) session))
                (push (list dir id meta
                            (org-glance-llm--role-from-provider-name provider-name)
                            provider-name file)
                      result)))))))
    (nreverse result)))

(cl-defun org-glance-llm--id-from-data-dir (graph dir)
  "Headline id encoded by GRAPH's content-addressable data directory DIR."
  (let* ((root (file-name-as-directory
                (expand-file-name (org-glance-graph:data-path graph))))
         (path (file-name-as-directory (expand-file-name dir))))
    (when (string-prefix-p root path)
      (let ((parts (split-string (directory-file-name
                                  (file-relative-name path root))
                                 "/" t)))
        (pcase parts
          (`(,short) (and (<= (length short) 2) short))
          (`(,shard ,rest) (and (= (length shard) 2) (concat shard rest))))))))

(cl-defun org-glance-llm--recorded-codex (graph)
  "Codex sessions for GRAPH; O(recorded).
Codex stores rollouts by date, so read each rollout's small metadata prefix,
deduplicate unnamed sessions by working directory, and preserve each named
session.  Project-directory overrides remain visible while their buffers live."
  (let ((store (expand-file-name (agnostic-llm--provider-get :session-dir)))
        (regexp (agnostic-llm--provider-get :session-file-regexp))
        (names (agnostic-llm--codex-name-index))
        (latest (make-hash-table :test 'equal))
        result)
    (when (file-directory-p store)
      (dolist (file (directory-files-recursively store regexp))
        (pcase-let ((`(,cwd . ,originator)
                     (agnostic-llm--codex-session-meta file)))
          (when (and cwd (equal originator "codex-tui"))
            (let* ((selector (agnostic-llm--codex-session-id file))
                   (provider-name (alist-get selector names nil nil #'equal))
                   (role (org-glance-llm--role-from-provider-name provider-name))
                   (key (cons cwd role)))
              (when (or (null (gethash key latest))
                        (file-newer-than-file-p file (car (gethash key latest))))
                (puthash key (cons file provider-name) latest)))))))
    (maphash
     (lambda (key record)
       (let ((cwd (car key))
             (role (cdr key)))
         (when-let* ((id (org-glance-llm--id-from-data-dir graph cwd))
                     (meta (org-glance-graph:get-headline graph id))
                     ((org-glance-headline-metadata? meta)))
           (push (list (org-glance-llm--dir graph id) id meta role
                       (cdr record) (car record))
                 result))))
     latest)
    (nreverse result)))

(cl-defun org-glance-llm--recorded (graph)
  "Active provider's recorded sessions for GRAPH; O(recorded), never O(headlines).
Claude's store encodes the project directory in each direct child.  Codex uses
date-partitioned rollouts whose metadata names the working directory."
  (if (eq agnostic-llm-provider 'codex)
      (org-glance-llm--recorded-codex graph)
    (org-glance-llm--recorded-encoded graph)))

(cl-defun org-glance-llm--row-for
    (dir id title buf &key session-name provider-name transcript)
  "Table row for the session at DIR (headline ID, may be nil) titled TITLE.
State and buffer name come from live BUF (or nil); `last' and `prompt' read
DIR's provider TRANSCRIPT and saved prompts.  SESSION-NAME and PROVIDER-NAME
identify a named conversation."
  `((id . ,(if session-name (format "%s#%s" dir session-name) dir))
    (dir . ,dir)
    (headline . ,id)
    (session-name . ,session-name)
    (provider-name . ,provider-name)
    (cells . ((provider . ,(symbol-name agnostic-llm-provider))
              (title . ,(or title ""))
              (name . ,(or session-name ""))
              (state . ,(org-glance-llm--state buf))
              (buffer . ,(if buf (buffer-name buf) ""))
              (last . ,(org-glance-llm--last
                        (or transcript (agnostic-llm--session-file dir))))
              (prompt . ,(if-let* ((p (org-glance-llm--last-prompt dir)))
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
      (puthash (cons (org-glance-llm--buffer-dir buf)
                     (buffer-local-value 'agnostic-llm-session-name buf))
               buf buf-by-dir))
    (dolist (rec (org-glance-llm--recorded graph))
      (pcase-let ((`(,dir ,id ,meta ,session-name ,provider-name ,transcript)
                   rec))
        (let* ((key (cons dir session-name))
               (buf (gethash key buf-by-dir)))
          (remhash key buf-by-dir)
          (push (org-glance-llm--row-for
                 dir id (org-glance-headline-metadata:title meta) buf
                 :session-name session-name :provider-name provider-name
                 :transcript transcript)
                rows))))
    (maphash (lambda (key buf)
               (let ((dir (car key))
                     (session-name (cdr key)))
               (push (org-glance-llm--row-for
                       dir nil (org-glance-llm--buffer-label buf) buf
                       :session-name session-name
                       :provider-name
                       (buffer-local-value 'agnostic-llm-session-label buf))
                      rows)))
             buf-by-dir)
    (nreverse rows)))

(defconst org-glance-llm--sessions-spec
  '((title . "org-glance llm sessions")
    (columns . (((key . "provider") (header . "Provider") (type . "badge") (sortable . t) (align . "left"))
                ((key . "state")  (header . "State")  (type . "badge") (sortable . t) (align . "left")
                 (badges . (((value . "running") (color . "#9ece6a"))
                            ((value . "exited")  (color . "#e0af68"))
                            ((value . "stopped") (color . "#565f89")))))
                ((key . "title")  (header . "Title")  (type . "text") (sortable . t) (align . "left"))
                ((key . "name")   (header . "Name")   (type . "text") (sortable . t) (align . "left"))
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

(cl-defun org-glance-llm--act-open (graph row)
  "Pop to ROW's running session in GRAPH or restart it.
The restarted session continues its transcript.
The label: the owning headline's title slug, else the old buffer's label,
else DIR's leaf."
  (let* ((dir (alist-get 'dir row))
         (session-name (alist-get 'session-name row))
         (buf (org-glance-llm--session-buffer
               dir :session-name session-name)))
    (if (and (buffer-live-p buf)
             (process-live-p (get-buffer-process buf)))
        (pop-to-buffer buf)
      (let* ((id (alist-get 'headline row))
             (meta (and id (org-glance-graph:get-headline graph id)))
             (label (cond ((org-glance-headline-metadata? meta)
                           (org-glance-llm--label meta dir))
                          (buf (org-glance-llm--buffer-label buf))
                          (t (file-name-nondirectory (directory-file-name dir))))))
        (agnostic-llm dir label session-name)))))

(cl-defun org-glance-llm--act-kill (row)
  "Kill ROW's live session buffer, after confirming."
  (let ((buf (org-glance-llm--session-buffer
              (alist-get 'dir row)
              :session-name (alist-get 'session-name row))))
    (cond ((not (buffer-live-p buf)) (user-error "No live session buffer"))
          ((y-or-n-p (format "Kill %s? " (buffer-name buf)))
           (let ((kill-buffer-query-functions nil))
             (kill-buffer buf))
           (table-view-refresh (current-buffer))
           (table-view-apply-sort)))))

(cl-defun org-glance-llm--act-materialize (graph row)
  "Materialize ROW's owning headline in GRAPH."
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
         (handlers (list (cons "open" (lambda (_id row) (org-glance-llm--act-open graph row)))
                         (cons "materialize" (lambda (_id row) (org-glance-llm--act-materialize graph row)))
                         (cons "kill" (lambda (_id row) (org-glance-llm--act-kill row)))
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
