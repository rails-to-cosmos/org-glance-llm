(package "org-glance-llm" "0.1.0.0.20260723.0"
         "LLM sessions for org-glance headlines")

(website-url "https://github.com/rails-to-cosmos/org-glance-llm")
(keywords "convenience" "outlines")

(package-file "org-glance-llm.el")
(files "*.el")


(script "test" "echo \"Error: no test specified\" && exit 1")

(source "gnu")
(source "melpa")
(source "rails-to-cosmos" "https://rails-to-cosmos.github.io/elpa/")

(depends-on "emacs" "29.1")
(depends-on "org-glance")
(depends-on "agnostic-llm")
(depends-on "table-view")

;; Dev-only: the linters (`make lint').
(development
 (depends-on "package-lint")
 (depends-on "relint"))

(eask-defcommand test
  "Run the ert suite.
A sibling org-glance checkout wins over the installed package (dev against
the core this plugin ships beside); the plugin file is loaded by PATH so a
stale copy bundled in an older org-glance can never shadow it."
  (setq ert-batch-backtrace-right-margin 1200)
  (let ((core (expand-file-name "../org-glance")))
    (when (file-directory-p core)
      (dolist (dir (list (expand-file-name "src/view" core)
                         (expand-file-name "src/data" core)
                         core))
        (add-to-list 'load-path dir))))
  (load (expand-file-name "org-glance-llm.el") nil t)
  (load "test/test-helpers.el")
  (load "test/test-llm.el")
  (ert-run-tests-batch-and-exit))
