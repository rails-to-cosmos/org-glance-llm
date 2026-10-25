(require 'package)
(require 'json)

(let ((desc (with-temp-buffer
              (insert-file-contents "org-glance-llm.el")
              (package-buffer-info))))
  (package (symbol-name (package-desc-name desc))
           (package-version-join (package-desc-version desc))
           (package-desc-summary desc))
  (dolist (requirement (package-desc-reqs desc))
    (depends-on (symbol-name (car requirement))
                (package-version-join (cadr requirement)))))

(website-url "https://github.com/rails-to-cosmos/org-glance-llm")
(keywords "convenience" "outlines")

(package-file "org-glance-llm.el")
(let* ((json-object-type 'alist)
       (json-key-type 'string)
       (json-array-type 'list)
       (spec (car (json-read-file "packages.json"))))
  (apply #'files (mapcar #'car (cdr (assoc "files" spec)))))


(script "test" "echo \"Error: no test specified\" && exit 1")

(source "gnu")
(source "melpa")
(source "rails-to-cosmos" "https://rails-to-cosmos.github.io/elpa/")


;; Dev-only: the linters (`make lint').
(development
 (depends-on "package-lint")
 (depends-on "relint"))

(eask-defcommand test
  "Run the ert suite.
A sibling org-glance checkout wins over the installed package (dev against
the core this plugin ships beside).  Every own file -- plugin and both test
files -- is loaded by ABSOLUTE path: `core' is on `load-path', and it ships
a `test/test-helpers.el' of its own, so a relative `load' would resolve to
the core copy and shadow this plugin's identically named fixtures."
  (setq ert-batch-backtrace-right-margin 1200)
  (let ((core (expand-file-name "../org-glance")))
    (when (file-directory-p core)
      (dolist (dir (list (expand-file-name "src/view" core)
                         (expand-file-name "src/data" core)
                         core))
        (add-to-list 'load-path dir))))
  (let ((agnostic (expand-file-name "../agnostic-llm")))
    (when (file-directory-p agnostic)
      (add-to-list 'load-path agnostic)))
  (provide 'vterm)
  (load (expand-file-name "org-glance-llm.el") nil t)
  (load (expand-file-name "test/test-helpers.el") nil t)
  (load (expand-file-name "test/test-llm.el") nil t)
  (ert-run-tests-batch-and-exit))
