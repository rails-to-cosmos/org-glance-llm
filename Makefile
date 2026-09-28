.PHONY: init test lint compile clean

# A sibling org-glance checkout is the reference core during development;
# override with CORE=/path when it lives elsewhere.  Falls back to the
# installed package when the checkout is absent.
CORE ?= ../org-glance

init:
	eask install-deps --dev
	make compile
	eask install

compile:
	eask exec emacs --batch -L . -L $(CORE) -L $(CORE)/src/data -L $(CORE)/src/view \
	  -f batch-byte-compile org-glance-llm.el

test:
	make clean
	make compile
	eask run command test

lint:
	make clean
	eask lint checkdoc
	eask lint regexps

clean:
	eask clean elc

# --- Version bumping ---------------------------------------------------------
# Versions are MAJOR.MINOR.PATCH.BUILD.YYYYMMDD.REV (package-build / ELPA style,
# e.g. 0.1.0.0.20260723.0).  `make major|minor|patch|build' bumps that base
# component, resets the lower base components, stamps today's date and resets
# REV; `make rev' bumps REV for another release the same day.  The version is
# written to both the Eask spec and the org-glance-llm.el header.
.PHONY: major minor patch build rev bump-version
major: BUMP := major
minor: BUMP := minor
patch: BUMP := patch
build: BUMP := build
rev:   BUMP := rev
major minor patch build rev: bump-version

bump-version:
	@set -e; \
	cur=`sed -n 's/^(package "org-glance-llm" "\([0-9.]*\)".*/\1/p' Eask`; \
	test -n "$$cur" || { echo "error: could not read version from Eask"; exit 1; }; \
	set -- `echo "$$cur" | tr '.' ' '`; \
	maj=$${1:-0}; min=$${2:-0}; pat=$${3:-0}; bld=$${4:-0}; olddate=$${5:-0}; rev=$${6:-0}; \
	today=`date +%Y%m%d`; \
	case "$(BUMP)" in \
	  major) maj=$$((maj+1)); min=0; pat=0; bld=0; rev=0 ;; \
	  minor) min=$$((min+1)); pat=0; bld=0; rev=0 ;; \
	  patch) pat=$$((pat+1)); bld=0; rev=0 ;; \
	  build) bld=$$((bld+1)); rev=0 ;; \
	  rev)   if [ "$$olddate" = "$$today" ]; then rev=$$((rev+1)); else rev=0; fi ;; \
	  *) echo "usage: make major|minor|patch|build|rev"; exit 1 ;; \
	esac; \
	new="$$maj.$$min.$$pat.$$bld.$$today.$$rev"; \
	ORG_GLANCE_LLM_OLD_VERSION="$$cur" ORG_GLANCE_LLM_NEW_VERSION="$$new" perl -pi -e \
	  's/^(\(package "org-glance-llm" ")\Q$$ENV{ORG_GLANCE_LLM_OLD_VERSION}\E(".*)/$$1.$$ENV{ORG_GLANCE_LLM_NEW_VERSION}.$$2/e' Eask; \
	ORG_GLANCE_LLM_NEW_VERSION="$$new" perl -pi -e \
	  's/^(;; Version: )[0-9][0-9.]*/$$1.$$ENV{ORG_GLANCE_LLM_NEW_VERSION}/e' org-glance-llm.el; \
	echo "org-glance-llm: $$cur -> $$new"
