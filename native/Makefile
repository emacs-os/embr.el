CC       ?= gcc
CFLAGS   ?= -O2 -Wall -Wextra -fPIC
LDFLAGS  ?= -shared
LIBS     ?= -ljpeg
ASAN_CFLAGS ?= -O0 -g3 -Wall -Wextra -fPIC -fno-omit-frame-pointer -fsanitize=address,undefined
ASAN_LDFLAGS ?= -shared -fsanitize=address,undefined

# Directory holding the emacs-module.h of the Emacs that will load the
# module.  Leave empty to use the compiler's default include path.
# embr.el passes the running Emacs's include directory when it finds one.
EMACS_INCLUDE ?=
ifneq ($(strip $(EMACS_INCLUDE)),)
CPPFLAGS += -I$(EMACS_INCLUDE)
endif

TARGET = embr-canvas.so
ASAN_TARGET = embr-canvas-asan.so

all: $(TARGET)

$(TARGET): embr-canvas.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

asan: $(ASAN_TARGET)

$(ASAN_TARGET): embr-canvas.c
	$(CC) $(CPPFLAGS) $(ASAN_CFLAGS) -o $@ $< $(ASAN_LDFLAGS) $(LIBS)

clean:
	rm -f $(TARGET) $(ASAN_TARGET)

.PHONY: all asan clean
