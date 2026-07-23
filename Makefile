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
