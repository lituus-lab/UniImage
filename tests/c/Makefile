# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Shell-free: `pwd` and `rm` are unavailable under mingw32-make on Windows.
ifeq ($(origin CC),default)
  ifeq ($(OS),Windows_NT)
    CC := gcc
  else
    CC := cc
  endif
endif

ROOT   := $(CURDIR)/../..
CFLAGS := -I$(ROOT)/include -O2 -Wall -Wextra -std=c11
LIB    := $(ROOT)/libUniImage.a

# The static library carries the macOS system HEIF decoder unless the build
# asked otherwise, and that decoder calls into the system frameworks. A
# consumer on a Mac links them; so must this.
UNAME := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME),Darwin)
  LDLIBS := -framework CoreFoundation -framework CoreGraphics -framework ImageIO
else
  # glibc keeps pow, atan2, cbrt and the rest out of libc; macOS folds them in,
  # which is why an empty list held here for so long.
  LDLIBS := -lm
endif

ifeq ($(OS),Windows_NT)
  BIN  := test_uniimage.exe
  RUN  := $(BIN)
  RM_F := del /q
else
  BIN  := test_uniimage
  RUN  := ./$(BIN)
  RM_F := rm -f
endif

.PHONY: all run clean
all: run
run: $(BIN)
	$(RUN)
$(BIN): test_uniimage.c $(ROOT)/include/UniImage.h $(LIB)
	$(CC) $(CFLAGS) -o $(BIN) test_uniimage.c $(LIB) $(LDLIBS)
# File target, not phony: `nimble ctest` already built the lib, don't redo it.
$(LIB):
	cd $(ROOT) && nimble clibStatic
clean:
	$(RM_F) $(BIN)
