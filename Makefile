# ApplesIDE -- an Applesoft editor for the Apple //e
#
#   make          assemble SRC with Merlin32
#   make disk     build a bootable ProDOS 8 image
#   make run      build, then boot it in Virtual ][
#   make screen   print what's on the emulated screen right now
#   make clean
#
# Deliberately smaller than ZipEdit's Makefile. The release, card, distribution
# and probe targets are not here because there is nothing to release yet, and a
# target that has never been run is worse than no target at all.

VERSION := 0.1

# Which language it speaks. Same machinery as ZipEdit: every word lives in
# lang/<code>.txt and tools/genlang.py turns it into src/lang.S on every build.
#
# LANG is also the shell's locale variable and is virtually always set, so
# `LANG ?= en` never fires -- a plain `make` would go looking for
# lang/en_US.UTF-8.txt. A value from the ENVIRONMENT is a locale and means
# nothing here; one given on the command line is a real choice.
ifeq ($(origin LANG),environment)
LANG    := en
endif
LANG    ?= en
LANGTXT := lang/$(LANG).txt
LANGUP  := $(shell echo $(LANG) | tr a-z A-Z)

ifeq ($(LANG),en)
LANGARG :=
else
LANGARG := --lang $(LANG)
endif

SRC     ?= src/aside.S
NAME    ?= ASIDE.SYSTEM
BUILD   := build
TOOLS   := tools

MERLIN  := $(TOOLS)/merlin32
ASMINC  := $(TOOLS)/asminc
AC      := $(TOOLS)/ac
VII     := $(TOOLS)/vii.sh

ifeq ($(LANG),en)
BIN     := $(BUILD)/$(NAME)
IMAGE   ?= $(BUILD)/APPLESIDE.po
else
BIN     := $(BUILD)/$(LANGUP)-$(NAME)
IMAGE   ?= $(BUILD)/APPLESIDE-$(LANGUP).po
endif

.PHONY: all disk run screen clean tools eject help card test

all: $(BIN)

# Every module is pulled in with `put`, so the binary depends on all of them
# rather than on $(SRC) alone. ZipEdit learned this one the hard way: depending
# on $(SRC) meant edits to the other modules silently did not rebuild, which
# produced a stale binary that looked like a runaway bug in new code.
$(BIN): $(wildcard src/*.S) $(LANGTXT) $(TOOLS)/genlang.py $(TOOLS)/genhelp.py $(TOOLS)/gentokens.py | $(BUILD)
	@python3 $(TOOLS)/gentokens.py > src/tokens.S
	@python3 $(TOOLS)/genlang.py $(LANGTXT) > src/lang.S
	@python3 $(TOOLS)/genhelp.py $(LANGARG) > src/helpdata.S
	@$(MERLIN) $(ASMINC) $(SRC) > $(BUILD)/merlin32.log 2>&1 || \
		{ echo "--- Merlin32 failed ---"; cat $(BUILD)/merlin32.log; exit 1; }
	@grep -iE '^\s+(Error|Warning)' $(BUILD)/merlin32.log && exit 1 || true
	@mv $(dir $(SRC))$(NAME) $(BIN)
	@rm -f $(dir $(SRC))_FileInformation.txt
	@echo "assembled $(SRC) -> $(BIN) ($$(stat -f%z $(BIN)) bytes)"

$(BUILD):
	@mkdir -p $(BUILD)

disk: $(IMAGE)

$(IMAGE): $(BIN)
	@VOL=APPLESIDE SYS=$(NAME) $(TOOLS)/mkdisk.sh $(IMAGE) $(BIN)

# SECTION runs one section on its own: make test SECTION="renumber"
test: $(IMAGE)
	@tests/run.sh "$(SECTION)"

run: $(IMAGE)
	@$(VII) boot $(IMAGE)
	@$(VII) settle 8
	@echo "--- screen ---"
	@$(VII) screen

screen:
	@$(VII) screen

# Virtual ][ buffers image writes until eject, so anything reading the image
# back on the Mac needs a flush first.
eject:
	@osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' 2>/dev/null || true
	@echo "ejected"

# Copy the built image to an SD or CF card for a Floppy Emu or CFFA.
#
#   make card VOL=EMU        the card's volume name as Finder shows it
#
# The Floppy Emu reads the card at block level and needs each image stored
# contiguously, so tools/tocard.sh deletes any previous copy, clears the macOS
# metadata that fragments a FAT volume, and writes the image fresh. It also
# lists every image left on the card, because an older build under a previous
# name still boots and is confusing to meet on the machine.
card: $(IMAGE)
	@$(TOOLS)/tocard.sh "$(or $(VOL),$(error set VOL to the card's volume name, e.g. make card VOL='NO NAME'))" $(IMAGE)

tools:
	@$(TOOLS)/bootstrap.sh

clean:
	@rm -rf $(BUILD) src/lang.S src/helpdata.S src/tokens.S src/_FileInformation.txt
	@echo "cleaned"

help:
	@echo "make          assemble $(SRC)"
	@echo "make disk     bootable image at $(IMAGE)"
	@echo "make run      build and boot it in Virtual ]["
	@echo "make LANG=xx  build in another language"
	@echo "make card VOL=NAME   copy the image to an SD card"
	@echo "make test      run the regression suite"
