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

# After BUILD, not before it. `:=` expands immediately, so defined any earlier
# this reads as /APPLESIDE-DIST.po -- the root of the filesystem -- and the
# build fails with "Read-only file system" while the stale image it should have
# replaced sits there looking current.
DISTIMG := $(BUILD)/APPLESIDE-DIST.po

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

.PHONY: cc bench all disk run screen clean tools eject help card test dist

all: $(BIN)

# dumcheck first: a dum block declares addresses without emitting anything, so
# two of them can claim the same bytes and Merlin says nothing. That is how
# SCRLOST came to sit on OLDGAP's low byte and switch off the cursor-only
# redraw one commit after it was measured. The build asks every time now.
#
# Every module is pulled in with `put`, so the binary depends on all of them
# rather than on $(SRC) alone. ZipEdit learned this one the hard way: depending
# on $(SRC) meant edits to the other modules silently did not rebuild, which
# produced a stale binary that looked like a runaway bug in new code.
$(BIN): $(wildcard src/*.S) $(LANGTXT) $(TOOLS)/genlang.py $(TOOLS)/genhelp.py $(TOOLS)/gentokens.py | $(BUILD)
	@python3 $(TOOLS)/gentokens.py > src/tokens.S
	@python3 $(TOOLS)/genlang.py $(LANGTXT) > src/lang.S
	@python3 $(TOOLS)/genhelp.py $(LANGARG) > src/helpdata.S
	@python3 $(TOOLS)/dumcheck.py
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

# A disk to give somebody. Unlike the build image it keeps BASIC.SYSTEM, so
# that quitting the editor lands somewhere a program can actually be run --
# ApplesIDE saves plain text, and EXEC from BASIC is how that becomes a
# running program until tokenised files are read directly. disk/README.TXT
# rides along saying so.
#
# BASIC.SYSTEM is added AFTER ours, because ProDOS launches the first .SYSTEM
# file in DIRECTORY ORDER and the disk has to come up in the editor.
dist: $(BIN) disk/README.TXT
	@RELEASE=1 VOL=APPLESIDE SYS=$(NAME) $(TOOLS)/mkdisk.sh $(DISTIMG) $(BIN) >/dev/null
	@$(AC) -p $(DISTIMG) README.TXT TXT < disk/README.TXT
	@echo "distribution image: $(DISTIMG)"
	@$(AC) -l $(DISTIMG)

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
# --- the compiler -------------------------------------------------------
# A separate program on the same disk, so the editor stays what it is for
# somebody who only wants an editor. Built from its own source; nothing in
# src/cc is put into the editor.
CCBIN  := $(BUILD)/ASIDECC.SYSTEM

$(CCBIN): $(wildcard src/cc/*.S) | $(BUILD)
	@python3 $(TOOLS)/dumcheck.py src/cc
	@$(MERLIN) $(ASMINC) src/cc/cc.S > $(BUILD)/cc-merlin32.log 2>&1 || \
		{ echo "--- Merlin32 failed ---"; cat $(BUILD)/cc-merlin32.log; exit 1; }
	@grep -iE '^\s+(Error|Warning)' $(BUILD)/cc-merlin32.log && exit 1 || true
	@mv src/cc/ASIDECC.SYSTEM $(CCBIN)
	@rm -f src/cc/_FileInformation.txt
	@echo "assembled src/cc/cc.S -> $(CCBIN) ($$(stat -f%z $(CCBIN)) bytes)"

cc: $(CCBIN)

# What Applesoft spends its time on, and how much of it a compiler could take
# away. Needs the dist image, and runs the machine at 1MHz for several minutes.
bench: dist
	@bench/bench.sh

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
# The DIST image, not the plain build one. The plain image carries the editor
# and nothing else, so a program saved on it cannot be run without another
# disk -- which is exactly the trap this target used to walk into.
# `card` DEPENDS ON THE PHONY `dist`, NOT on the image file. It used to name
# the file, which nothing had a rule to build -- so make saw it already existed,
# pronounced it up to date, and tocard.sh faithfully copied a months-stale
# image. The tester then reported a feature missing that had been built and
# tested hours before. Depending on `dist` rebuilds it every time.
#
# And then it CHECKS, because the image's timestamp was newer than the binary's
# while its contents were older -- an mtime is not evidence. mkdisk.sh already
# refuses to hand back an image whose SYS file does not match the binary; this
# is the same check one step further along, against what actually landed on
# the card.
card: dist
	@$(TOOLS)/tocard.sh "$(or $(VOL),$(error set VOL to the card's volume name, e.g. make card VOL='NO NAME'))" $(DISTIMG)
	@$(AC) -g "/Volumes/$(VOL)/$(notdir $(DISTIMG))" $(NAME) > $(BUILD)/.cardcheck 2>/dev/null; \
	 if cmp -s $(BUILD)/.cardcheck $(BIN); then \
	   echo "verified: $(NAME) on the card is the one in $(BUILD)"; \
	 else \
	   echo "ERROR: the card's $(NAME) is NOT the current build" >&2; \
	   echo "  card:  $$(stat -f%z $(BUILD)/.cardcheck 2>/dev/null || echo absent) bytes" >&2; \
	   echo "  build: $$(stat -f%z $(BIN)) bytes" >&2; \
	   exit 1; \
	 fi

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
	@echo "make card VOL=NAME   copy the DIST image to an SD card"
	@echo "make test      run the regression suite"
	@echo "make dist      an image to give away: adds BASIC.SYSTEM + README"
