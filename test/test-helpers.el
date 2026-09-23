;;; test-helpers.el --- Fixtures for the org-glance-llm suite  -*- lexical-binding: t -*-

;;; Commentary:
;; A lean copy of the fixtures this plugin's tests need.  org-glance does not
;; ship its test helpers (tests are not packaged), so a plugin repo carries
;; its own; keep this file to what the suite actually uses.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 's)
(require 'f)
(require 'table-view)
(require 'org-glance)
(require 'org-glance-llm)

(cl-defmacro with-temp-directory (dir &rest body)
  "Bind DIR to a fresh temporary directory for BODY; delete it afterward."
  (declare (indent 1))
  `(let ((,dir (make-temp-file "org-glance-llm-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,dir t))))

(cl-defmacro org-glance-test:with-graph (graph &rest body)
  "Create a graph in a fresh temp directory, bind it to GRAPH, run BODY."
  (declare (indent 1))
  `(with-temp-directory dir
     (let ((,graph (org-glance-graph dir)))
       ,@body)))

(cl-defmacro org-glance-test:session (&rest body)
  "Initialize org-glance in a temp directory and run BODY."
  (declare (indent 0))
  `(with-temp-directory org-glance-directory
     (org-glance-init org-glance-directory)
     ,@body))

(cl-defun org-glance-test:headline-props (id heading props &rest body)
  "Build a headline: HEADING, planning lines from BODY's head, the drawer
\(ORG_GLANCE_ID + PROPS as (KEY . VALUE) pairs), then the rest of BODY."
  (let* ((planning (seq-take-while
                    (lambda (l) (string-match-p "^\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):" l))
                    body))
         (rest (seq-drop body (length planning))))
    (apply #'org-glance-headline--from-lines
           (append (list heading) planning
                   (list ":PROPERTIES:" (format ":ORG_GLANCE_ID: %s" id))
                   (mapcar (lambda (kv) (format ":%s: %s" (car kv) (cdr kv))) props)
                   (list ":END:")
                   rest))))

(cl-defun org-glance-test:headline (id &rest lines)
  "Build a headline carrying ID from LINES (heading, planning, body)."
  (apply #'org-glance-test:headline-props id (car lines) nil (cdr lines)))

(cl-defmacro org-glance-test:with-open (buf open-form &rest body)
  "Bind BUF to OPEN-FORM, run BODY, then kill BUF if still live."
  (declare (indent 2))
  `(let ((,buf ,open-form))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p ,buf) (kill-buffer ,buf)))))

(cl-defmacro org-glance-test:with-shown ((var) &rest body)
  "Stub `switch-to-buffer'/`pop-to-buffer' to record shown buffers in VAR.
Every shown buffer is killed on exit -- a leaked `*llm:…*' buffer would be
found by the next test's live-session scan."
  (declare (indent 1))
  (let ((all (gensym "shown-all")))
    `(let (,var ,all)
       (unwind-protect
           (cl-letf (((symbol-function 'switch-to-buffer)
                      (lambda (b &rest _) (push b ,all) (setq ,var b) b))
                     ((symbol-function 'pop-to-buffer)
                      (lambda (b &rest _) (push b ,all) (setq ,var b) b)))
             ,@body)
         (dolist (b ,all)
           (when (buffer-live-p b)
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))))))

(cl-defmacro org-glance-test:with-llm-buffer ((var name dir) &rest body)
  "Create active-provider `*llm:NAME*' buffer VAR rooted at DIR."
  (declare (indent 1))
  `(let ((,var (get-buffer-create (format "*llm:%s*" ,name)))
         (provider agnostic-llm-provider))
     (unwind-protect
         (progn
           (with-current-buffer ,var
             (setq default-directory (file-name-as-directory ,dir))
             (setq-local agnostic-llm-provider provider))
           ,@body)
       (kill-buffer ,var))))

(cl-defun org-glance-test:goto-cell (id key)
  "Move point to row ID's KEY cell in the current table buffer, by key."
  (table-view--goto-id id)
  (table-view--goto-cell key)
  (should (equal key (get-text-property (point) 'table-view-col))))

(cl-defun org-glance-test:table-cell (id key &optional (buf (current-buffer)))
  "Cell KEY of row ID in table BUF (default: current buffer)."
  (with-current-buffer buf
    (table-view--cell (cl-find id table-view--rows
                               :key (lambda (r) (alist-get 'id r)) :test #'equal)
                      key)))

(provide 'test-helpers)
;;; test-helpers.el ends here
