EMACS ?= emacs
PYTHON ?= python3
SHELLCHECK ?= shellcheck

test: checkparens bytecompile checkpy shellcheck

check: test

checkparens:
	$(EMACS) --batch --eval '(find-file "embr.el")' --eval '(check-parens)' && echo "OK: parens balanced"

bytecompile:
	$(EMACS) --batch -L . -f batch-byte-compile embr.el && rm -f embr.elc && echo "OK: embr.el byte-compiles cleanly"

checkpy:
	$(PYTHON) -m py_compile embr.py && echo "OK: embr.py syntax valid"

shellcheck:
	$(SHELLCHECK) setup.sh uninstall.sh && echo "OK: shell scripts pass shellcheck"

.PHONY: test check checkparens bytecompile checkpy shellcheck
