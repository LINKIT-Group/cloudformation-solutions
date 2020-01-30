# --------------------------------------------------------------------
# Copyright (c) 2020 Anthony Potappel - LINKIT, The Netherlands.
# SPDX-License-Identifier: MIT
# --------------------------------------------------------------------

CC = python3
ODIR = build

TARGET = $(ODIR)/Makefile

OBJECTS := $(shell find src -name '*.template' -o -name '*.sh' -o -name '*.txt')

$(TARGET): $(OBJECTS) generate.py
	[ -d build ] || mkdir build
	$(CC) ./generate.py >build/Makefile

.PHONY: test
test:
	$(CC) tests/validate_pipelines.py

.PHONY: install
install: $(ODIR)/Makefile test
	cp $(TARGET) ../../Makefile

.PHONY: clean
clean:
	rm -rf build
