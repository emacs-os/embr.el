CC       ?= gcc
CFLAGS   ?= -O2 -Wall -Wextra
LDFLAGS  ?=
PKG_CONFIG ?= pkg-config
ASAN_CFLAGS ?= -O0 -g3 -Wall -Wextra -fno-omit-frame-pointer -fsanitize=address,undefined
ASAN_LDFLAGS ?= -fsanitize=address,undefined

# Directory holding the emacs-module.h of the Emacs that will load the
# module.  Leave empty to use the compiler's default include path.
# embr.el passes the running Emacs's include directory when it finds one.
EMACS_INCLUDE ?=
ifneq ($(strip $(EMACS_INCLUDE)),)
CPPFLAGS += -I$(EMACS_INCLUDE)
endif

# libjpeg-turbo: ask pkg-config where it lives (Homebrew and other
# non-default prefixes); fall back to the default search path.
JPEG_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags libjpeg 2>/dev/null)
LIBS        ?= $(shell $(PKG_CONFIG) --libs libjpeg 2>/dev/null || echo -ljpeg)

# -fPIC and -shared are required for a loadable module, so they are
# not part of the overridable CFLAGS/LDFLAGS.
MODULE_CFLAGS  = -fPIC
MODULE_LDFLAGS = -shared

TARGET = embr-canvas.so
ASAN_TARGET = embr-canvas-asan.so

all: $(TARGET)

$(TARGET): embr-canvas.c
	$(CC) $(CPPFLAGS) $(JPEG_CFLAGS) $(CFLAGS) $(MODULE_CFLAGS) -o $@ $< $(MODULE_LDFLAGS) $(LDFLAGS) $(LIBS)

asan: $(ASAN_TARGET)

$(ASAN_TARGET): embr-canvas.c
	$(CC) $(CPPFLAGS) $(JPEG_CFLAGS) $(ASAN_CFLAGS) $(MODULE_CFLAGS) -o $@ $< $(MODULE_LDFLAGS) $(ASAN_LDFLAGS) $(LIBS)

clean:
	rm -f $(TARGET) $(ASAN_TARGET)

.PHONY: all asan clean
