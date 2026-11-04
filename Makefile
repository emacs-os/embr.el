EMACS ?= emacs
PYTHON ?= python3
SHELLCHECK ?= shellcheck

test: checkparens bytecompile checkpy shellcheck

check: test

checkparens:
	$(EMACS) --batch --eval '(find-file "embr.el")' --eval '(check-parens)' && echo "OK: embr.el parens balanced"
	$(EMACS) --batch --eval '(find-file "embr-passwd.el")' --eval '(check-parens)' && echo "OK: embr-passwd.el parens balanced"

bytecompile:
	$(EMACS) --batch -L . -f batch-byte-compile embr.el && rm -f embr.elc && echo "OK: embr.el byte-compiles cleanly"
	$(EMACS) --batch -L . -f batch-byte-compile embr-passwd.el && rm -f embr-passwd.elc && echo "OK: embr-passwd.el byte-compiles cleanly"

checkpy:
	$(PYTHON) -m py_compile embr.py && echo "OK: embr.py syntax valid"
	$(PYTHON) -m py_compile tools/embr-perf-report.py && echo "OK: embr-perf-report.py syntax valid"

shellcheck:
	$(SHELLCHECK) setup.sh && echo "OK: shell scripts pass shellcheck"

# Native canvas module — requires Emacs 32+ (native canvas images) + libjpeg-turbo.
# Pass EMACS_INCLUDE=/path/to/include if emacs-module.h is not on the default path.
module:
	$(MAKE) -C native

.PHONY: test check checkparens bytecompile checkpy shellcheck module
