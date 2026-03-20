EMACS ?= emacs
PYTHON ?= python3

test: checkparens checkpy

check: test

checkparens:
	$(EMACS) --batch --eval '(find-file "embr.el")' --eval '(check-parens)' && echo "OK: parens balanced"

checkpy:
	$(PYTHON) -m py_compile embr.py && echo "OK: embr.py syntax valid"
