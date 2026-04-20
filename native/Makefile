CC       ?= gcc
CFLAGS   ?= -O2 -Wall -Wextra -fPIC
LDFLAGS  ?= -shared
LIBS     ?= -ljpeg
ASAN_CFLAGS ?= -O0 -g3 -Wall -Wextra -fPIC -fno-omit-frame-pointer -fsanitize=address,undefined
ASAN_LDFLAGS ?= -shared -fsanitize=address,undefined

TARGET = embr-canvas.so
ASAN_TARGET = embr-canvas-asan.so

all: $(TARGET)

$(TARGET): embr-canvas.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)

asan: $(ASAN_TARGET)

$(ASAN_TARGET): embr-canvas.c
	$(CC) $(ASAN_CFLAGS) -o $@ $< $(ASAN_LDFLAGS) $(LIBS)

clean:
	rm -f $(TARGET) $(ASAN_TARGET)

.PHONY: all asan clean
