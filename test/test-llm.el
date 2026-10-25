;;; test-llm.el --- Tests for org-glance-llm  -*- lexical-binding: t -*-

(require 'test-helpers)

(ert-deftest org-glance-test:llm-materializes-then-opens-menu ()
  "`org-glance-llm' materializes the headline, then opens `agnostic-llm-menu'
pinned to its data dir and title label."
  (require 'agnostic-llm)
  (org-glance-test:session
    (org-glance-graph:add org-glance-graph
                          (org-glance-test:headline "llmid" "* TODO Alpha :x:" "body"))
    (let ((root 'unset) (label 'unset) header)
      (org-glance-test:with-shown (mat)
        (cl-letf (((symbol-function 'completing-read) (lambda (_p coll &rest _) (caar coll)))
                  ((symbol-function 'agnostic-llm-menu)
                   (lambda (&optional dir lbl)
                     (setq root dir label lbl)
                     (cl-letf (((symbol-function 'transient-scope)
                                (lambda () (list :root dir :label lbl)))
                               ((symbol-function 'transient-get-value)
                                (lambda () '("--session-name=worker"))))
                       (setq header
                             (substring-no-properties
                              (agnostic-llm--menu-header)))))))
          (org-glance-llm))
        (let ((expected (org-glance-graph:headline-data-path org-glance-graph "llmid")))
          (should (s-suffix? "/" root))          ; directory-valued, slash-terminated
          (should (file-equal-p root expected))
          (should (file-directory-p root))
          (should (equal "alpha" label))
          (should (string-suffix-p
                   " buffer=*llm:alpha-worker*" header))
          ;; the headline was materialized (its blob buffer) before the menu
          (should (buffer-live-p mat))
          (with-current-buffer mat (should org-glance-material-mode)))))))

(ert-deftest org-glance-test:llm-live-session-still-opens-name-menu ()
  "A live default session does not hide the menu for selecting another name."
  (org-glance-test:session
    (org-glance-graph:add org-glance-graph
                          (org-glance-test:headline "llmid" "* TODO Alpha :x:"))
    (let ((dir (org-glance-graph:headline-data-path org-glance-graph "llmid"))
          (menu-called nil))
      (make-directory dir t)
      (org-glance-test:with-llm-buffer (buf "alpha" dir)
        (org-glance-test:with-shown (shown)
          (cl-letf (((symbol-function 'completing-read) (lambda (_p coll &rest _) (caar coll)))
                    ((symbol-function 'agnostic-llm-menu) (lambda (&rest _) (setq menu-called t))))
            (org-glance-llm)
            (should-not (eq shown buf))
            (should menu-called)))))))

(ert-deftest org-glance-test:llm-session-identity-includes-provider ()
  "Claude and Codex sessions rooted at one headline remain distinct."
  (with-temp-directory dir
    (let ((agnostic-llm-provider 'claude))
      (org-glance-test:with-llm-buffer (claude "same" dir)
        (let ((agnostic-llm-provider 'codex))
          (org-glance-test:with-llm-buffer (codex "same-codex" dir)
            (should (eq codex (org-glance-llm--session-buffer dir)))
            (should (equal (list codex) (org-glance-llm--live-buffers)))
            (should (eq claude (org-glance-llm--session-buffer
                                dir :provider 'claude)))))))))

(ert-deftest org-glance-test:llm-session-identity-includes-name ()
  "Two named sessions for one provider and root remain distinct."
  (with-temp-directory dir
    (org-glance-test:with-llm-buffer
        (worker "project-worker" dir "worker" "project--worker")
      (org-glance-test:with-llm-buffer
          (reviewer "project-reviewer" dir "reviewer" "project--reviewer")
        (should (eq worker (org-glance-llm--session-buffer
                            dir :session-name "worker")))
        (should (eq reviewer (org-glance-llm--session-buffer
                              dir :session-name "reviewer")))
        (should-not (org-glance-llm--session-buffer dir))))))

(ert-deftest org-glance-test:llm-slug-and-collision ()
  "`org-glance-llm--slug' normalises a title; `--label' disambiguates only when
a session for a different headline already holds the plain slug."
  (should (equal "buy-milk-2l" (org-glance-llm--slug "Buy milk (2L)!")))
  (should (equal "hello-world" (org-glance-llm--slug "  Hello  World  ")))
  (should-not (org-glance-llm--slug "###"))
  (with-temp-directory dir
    (let* ((md (make-org-glance-headline-metadata :id "abcdef123" :title "Foo Bar"))
           (mine (f-join dir "mine")) (other (f-join dir "other")))
      (make-directory mine t) (make-directory other t)
      ;; no clash -> plain slug
      (should (equal "foo-bar" (org-glance-llm--label md mine)))
      ;; a *llm:foo-bar* rooted elsewhere -> disambiguate with the dir leaf
      (org-glance-test:with-llm-buffer (buf "foo-bar" other)
        (should (equal "foo-bar-mine" (org-glance-llm--label md mine)))
        ;; same root -> reuse the plain slug
        (with-current-buffer buf (setq default-directory (file-name-as-directory mine)))
        (should (equal "foo-bar" (org-glance-llm--label md mine)))))))

(ert-deftest org-glance-test:llm-dir-uses-project-property ()
  "`org-glance-llm--dir' returns `ORG_GLANCE_PROJECT_DIR' when set, else data dir."
  (org-glance-test:session
    (org-glance-graph:add org-glance-graph
      (org-glance-test:headline-props "a" "* TODO A" '(("ORG_GLANCE_PROJECT_DIR" . "~/x/proj")))
      (org-glance-test:headline "b" "* TODO B"))
    ;; directory-valued: always trailing-slashed (feeds `default-directory')
    (should (equal (file-name-as-directory (expand-file-name "~/x/proj"))
                   (org-glance-llm--dir org-glance-graph "a")))
    (should (equal (file-name-as-directory
                    (org-glance-graph:headline-data-path org-glance-graph "b"))
                   (org-glance-llm--dir org-glance-graph "b")))))

(ert-deftest org-glance-test:llm-honours-project-dir ()
  "`org-glance-llm' opens the session in a headline's `ORG_GLANCE_PROJECT_DIR'."
  (org-glance-test:session
    (let ((proj (make-temp-file "og-proj" t)))
      (org-glance-graph:add org-glance-graph
        (org-glance-headline--from-lines "* TODO Proj" ":PROPERTIES:" ":ORG_GLANCE_ID: p"
                                         (format ":ORG_GLANCE_PROJECT_DIR: %s" proj) ":END:"))
      (let ((root 'unset))
        (org-glance-test:with-shown (_shown)
          (cl-letf (((symbol-function 'completing-read) (lambda (_p coll &rest _) (caar coll)))
                    ((symbol-function 'agnostic-llm-menu) (lambda (&optional dir _lbl) (setq root dir))))
            (org-glance-llm)))
        (should (file-equal-p root proj))))))

;;; Sessions table

(cl-defmacro org-glance-test:llm-stubs ((store) &rest body)
  "Stub the agnostic-llm seam against temp session store STORE for BODY.
Mirrors the provider layout: session dirs encode [/.] as dashes under STORE;
the newest `.jsonl' inside is the transcript; prompt history is empty."
  (declare (indent 1))
  `(with-temp-directory ,store
     (cl-letf* (((symbol-function 'agnostic-llm--provider-get)
                 (lambda (key) (pcase key
                                 (:session-dir ,store)
                                 (:session-file-regexp "\\.jsonl\\'"))))
                ((symbol-function 'agnostic-llm--session-dir)
                 (lambda (dir)
                   (expand-file-name
                    (replace-regexp-in-string
                     "[/.]" "-" (directory-file-name (expand-file-name dir)))
                    ,store)))
                ((symbol-function 'agnostic-llm--session-file)
                 (lambda (dir)
                   (let ((sdir (agnostic-llm--session-dir dir)))
                     (and (file-directory-p sdir)
                          (car (directory-files sdir t "\\.jsonl\\'" t))))))
                ((symbol-function 'agnostic-llm--prompt-history-files)
                 (lambda (&optional _) nil))
                ((symbol-function 'agnostic-llm--named-sessions)
                 (lambda (_dir) nil))
                ((symbol-function 'agnostic-llm--prompt-preview) #'identity))
       ,@body)))

(cl-defun org-glance-test:llm-record-session (dir)
  "Record a fake provider transcript for session DIR."
  (let ((sdir (agnostic-llm--session-dir dir)))
    (make-directory sdir t)
    (with-temp-file (expand-file-name "s.jsonl" sdir) (insert "{}"))))

(ert-deftest org-glance-test:llm-codex-recorded-sessions ()
  "Codex's date-partitioned rollouts map their CWD back to a headline."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph (org-glance-test:headline "abcdef" "* TODO Alpha"))
    (with-temp-directory store
      (let* ((agnostic-llm-provider 'codex)
             (dir (org-glance-llm--dir graph "abcdef"))
             (rollout (expand-file-name "2026/09/23/rollout-test.jsonl" store)))
        (make-directory (file-name-directory rollout) t)
        (with-temp-file rollout (insert "{}"))
        (cl-letf (((symbol-function 'agnostic-llm--provider-get)
                   (lambda (key) (pcase key
                                   (:session-dir store)
                                   (:session-file-regexp "rollout-.*\\.jsonl\\'"))))
                  ((symbol-function 'agnostic-llm--codex-session-meta)
                   (lambda (_file) (cons dir "codex-tui")))
                  ((symbol-function 'agnostic-llm--codex-name-index)
                   (lambda () nil))
                  ((symbol-function 'agnostic-llm--codex-session-id)
                   (lambda (_file) nil)))
          (let ((recorded (org-glance-llm--recorded graph)))
            (should (= 1 (length recorded)))
            (should (equal "abcdef" (cadar recorded)))))))))

(ert-deftest org-glance-test:llm-sessions-state ()
  "State machine: no buffer -> stopped; dead buffer -> exited; live -> running."
  (should (equal "stopped" (org-glance-llm--state nil)))
  (org-glance-test:with-open buf (get-buffer-create " *llm-state-test*")
    (should (equal "exited" (org-glance-llm--state buf)))
    (let ((proc (start-process "llm-state" buf "sleep" "10")))
      (unwind-protect
          (should (equal "running" (org-glance-llm--state buf)))
        (set-process-query-on-exit-flag proc nil)
        (delete-process proc)))))

(ert-deftest org-glance-test:llm-buffer-label ()
  "`--buffer-label' unwraps `*llm:LABEL*', uniquify suffix included."
  (with-temp-buffer
    (rename-buffer "*llm:foo*" t)
    (should (equal "foo" (org-glance-llm--buffer-label (current-buffer)))))
  (with-temp-buffer
    (rename-buffer "*llm:foo*<2>" t)
    (should (equal "foo" (org-glance-llm--buffer-label (current-buffer))))))

(ert-deftest org-glance-test:llm-sessions-rows ()
  "Rows: recorded-but-dead headline sessions are `stopped'; live non-headline
buffers appear as `exited'/`running'; headlines without sessions are absent."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph
      (org-glance-test:headline "a" "* TODO Alpha :x:")
      (org-glance-test:headline "b" "* TODO Beta :x:"))
    (org-glance-test:llm-stubs (store)
      (org-glance-test:llm-record-session (org-glance-llm--dir graph "a"))
      (with-temp-directory extra
        (org-glance-test:with-llm-buffer (buf "extra" extra)
          (let* ((rows (org-glance-llm--session-rows graph))
                       (arow (cl-find "a" rows :key (lambda (r) (alist-get 'headline r))
                                      :test #'equal))
                       (xrow (cl-find "*llm:extra*" rows
                                      :key (lambda (r) (alist-get 'buffer (alist-get 'cells r)))
                                      :test #'equal)))
                  (should (= 2 (length rows)))          ; b has no session
                  (should arow)
                  (let ((cells (alist-get 'cells arow)))
                    (should (equal "Alpha" (alist-get 'title cells)))
                    (should (equal "stopped" (alist-get 'state cells)))
                    (should (s-present? (alist-get 'last cells))))
                  (should xrow)
                  (should-not (alist-get 'headline xrow))
                  (let ((cells (alist-get 'cells xrow)))
                    (should (equal "extra" (alist-get 'title cells)))
                    (should (equal "exited" (alist-get 'state cells))))))))))

(ert-deftest org-glance-test:llm-recorded-name-survives-table-and-restart ()
  "A stopped provider-named session keeps its role in the table and restart."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph
      (org-glance-test:headline "a" "* TODO Org Glance"))
    (org-glance-test:llm-stubs (store)
      (let* ((dir (org-glance-llm--dir graph "a"))
             (provider-dir (agnostic-llm--session-dir dir))
             (file (expand-file-name "named.jsonl" provider-dir))
             started)
        (make-directory provider-dir t)
        (with-temp-file file (insert "{}"))
        (cl-letf (((symbol-function 'agnostic-llm--named-sessions)
                   (lambda (_dir)
                     (list (list "org-glance--worker" "session-id" file))))
                  ((symbol-function 'agnostic-llm)
                   (lambda (&optional root label session-name)
                     (setq started (list root label session-name)))))
          (let* ((rows (org-glance-llm--session-rows graph))
                 (row (car rows))
                 (cells (alist-get 'cells row)))
            (should (= 1 (length rows)))
            (should (equal "worker" (alist-get 'name cells)))
            (should (equal "stopped" (alist-get 'state cells)))
            (org-glance-llm--act-open graph row)
            (should (equal (list dir "org-glance" "worker") started))))))))

(ert-deftest org-glance-test:llm-sessions-open-restarts-stopped ()
  "RET on a stopped headline session starts `agnostic-llm' with the session
dir and the headline's title-slug label."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph (org-glance-test:headline "a" "* TODO Alpha :x:"))
    (org-glance-test:llm-stubs (store)
      (let* ((dir (org-glance-llm--dir graph "a"))
             (row `((id . ,dir) (dir . ,dir) (headline . "a")))
             (started nil))
        (cl-letf (((symbol-function 'agnostic-llm)
                   (lambda (&optional root label session-name)
                     (setq started (list root label session-name)))))
          (org-glance-llm--act-open graph row))
        (should (equal dir (car started)))
        (should (equal "alpha" (cadr started)))
        (should-not (caddr started))))))

(ert-deftest org-glance-test:llm-sessions-visit ()
  "The sessions table renders one row per session from the provider store."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph (org-glance-test:headline "a" "* TODO Alpha :x:"))
    (org-glance-test:llm-stubs (store)
      (org-glance-test:llm-record-session (org-glance-llm--dir graph "a"))
      (org-glance-test:with-shown (buf)
        (setq buf (org-glance-llm-sessions:visit graph))
        (with-current-buffer buf
          (should (string= "*org-glance-llm-sessions*" (buffer-name)))
          (should (= 1 (length table-view--rows)))
          (should (equal "stopped"
                         (org-glance-test:table-cell
                          (org-glance-llm--dir graph "a") "state"))))))))

(ert-deftest org-glance-test:llm-sessions-live-refresh ()
  "No cache -- the provider store is the source of truth: a session recorded
after the first render appears on the very next `--session-rows' with no
rescan step, and a live buffer absent from the store shows as a live row."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph
      (org-glance-test:headline "c1" "* TODO Coffee :coffee:")
      (org-glance-test:headline "x1" "* TODO Other :misc:"))
    (org-glance-test:llm-stubs (store)
      (org-glance-test:llm-record-session (org-glance-llm--dir graph "c1"))
      (should (= 1 (length (org-glance-llm--session-rows graph))))
      ;; a newly recorded session is picked up immediately -- nothing to invalidate
      (org-glance-test:llm-record-session (org-glance-llm--dir graph "x1"))
      (should (= 2 (length (org-glance-llm--session-rows graph))))
      ;; live overlay: a buffer rooted outside the store shows as a live row
      (with-temp-directory extra
        (org-glance-test:with-llm-buffer (buf "orphan" extra)
          (let ((rows (org-glance-llm--session-rows graph)))
            (should (= 3 (length rows)))
            (should (cl-find "exited" rows
                             :key (lambda (r) (alist-get 'state (alist-get 'cells r)))
                             :test #'equal))))))))

(ert-deftest org-glance-test:llm-sessions-empty ()
  "A store with no session for the graph yields no rows, stably across calls."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph (org-glance-test:headline "a" "* TODO Alpha"))
    (org-glance-test:llm-stubs (store)
      (should-not (org-glance-llm--session-rows graph))
      (should-not (org-glance-llm--session-rows graph)))))

(ert-deftest org-glance-test:llm-provider-description ()
  "The provider choice shows its current value like the model choice."
  (let ((agnostic-llm-provider 'codex))
    (should (equal "Provider [codex]"
                   (org-glance-llm--provider-description))))
  (should (eq t (oref (get 'org-glance-llm--menu-set-provider
                           'transient--suffix)
                       transient))))

(ert-deftest org-glance-test:llm-provider-option-beside-model ()
  "`-p' precedes `-m' in options and remains unique after registration."
  (require 'agnostic-llm)
  (org-glance-llm--install-provider-option)
  (should-error (transient-get-suffix 'agnostic-llm-menu "B"))
  (should (equal 'org-glance-llm--menu-set-provider
                 (plist-get (cdr (transient-get-suffix 'agnostic-llm-menu "-p"))
                            :command)))
  (let* ((layout (get 'agnostic-llm-menu 'transient--layout))
         (options (aref (car (aref layout 2)) 2))
         (keys (mapcar (lambda (suffix) (plist-get (cdr suffix) :key)) options)))
    (should (equal '("-p" "-m")
                   (cl-subseq keys (cl-position "-p" keys :test #'equal)
                              (1+ (cl-position "-m" keys :test #'equal)))))
    (should (= 1 (cl-count "-p" keys :test #'equal)))))

(ert-deftest org-glance-test:llm-provider-stays-in-llm-menu ()
  "Provider selection stays in the LLM menu and clears old catalog choices."
  (let ((agnostic-llm-provider 'claude)
        cleared)
    (cl-letf (((symbol-function 'agnostic-llm-set-provider)
               (lambda () (interactive) (setq agnostic-llm-provider 'codex)))
              ((symbol-function 'transient-suffix-object)
               (lambda (command) command))
              ((symbol-function 'transient-infix-set)
               (lambda (infix value) (push (cons infix value) cleared))))
      (org-glance-llm--menu-set-provider)
      (should (eq agnostic-llm-provider 'codex))
      (should (equal '((agnostic-llm--menu-effort-option)
                       (agnostic-llm--menu-model-option))
                     cleared)))))

(ert-deftest org-glance-test:llm-plugin-registration ()
  "Loading the plugin registers `l' / `L' in the transient; the loader
survives an unknown plugin; `org-glance-plugin-enable' enables + records."
  ;; self-registered transient row (org-glance-ui + this plugin are loaded).
  ;; `transient-get-suffix' SIGNALS when absent, so the calls are the check.
  (should-error (transient-get-suffix 'org-glance-transient "P"))
  (transient-get-suffix 'org-glance-transient "l")
  (transient-get-suffix 'org-glance-transient "L")
  ;; ...and the material-buffer key: C-c l = this headline's session
  (should (eq (lookup-key org-glance-material-mode-map (kbd "C-c l"))
              #'org-glance-llm-here))
  ;; demoted loader: unknown plugin never breaks init
  (let ((org-glance-plugins '(no-such-plugin-xyz)))
    (org-glance--load-plugins))                ; demoted: must not signal
  ;; a plugin whose package is not installed says so, loudly
  (let ((org-glance-plugins nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "nope-xyz")))
      (should-error (call-interactively #'org-glance-plugin-enable) :type 'user-error))
    (should-not org-glance-plugins))
  ;; enable command: loads + records (batch skips customize-save)
  (let ((org-glance-plugins nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "llm")))
      (call-interactively #'org-glance-plugin-enable))
    (should (equal '(llm) org-glance-plugins))))

(ert-deftest org-glance-test:llm-sessions-refresh-keeps-cell ()
  "`g' in the sessions table restores the (row, cell) pair like the
headline table -- point never drops to the buffer top."
  (org-glance-test:with-graph graph
    (org-glance-graph:add graph (org-glance-test:headline "a" "* TODO Alpha"))
    (org-glance-test:llm-stubs (store)
      (org-glance-test:llm-record-session (org-glance-llm--dir graph "a"))
      (org-glance-test:with-shown (buf)
        (setq buf (org-glance-llm-sessions:visit graph))
        (with-current-buffer buf
          (org-glance-test:goto-cell (org-glance-llm--dir graph "a") "title")
          (funcall (cdr (assoc "refresh" table-view--handlers)) nil nil)
          (should (equal "title" (get-text-property (point) 'table-view-col))))))))

(provide 'test-llm)
;;; test-llm.el ends here
