EXEC   := snapcap
CONFIG := release

BIN := $(shell swift build -c $(CONFIG) --show-bin-path)/$(EXEC)

## Local, untracked settings. Copy .env.example to .env and edit.
##
## `-include` so a missing .env is not an error: `make build` must work in a fresh
## clone. Values are plain `KEY=value` make assignments — do not quote them, or the
## quotes become part of the value.
-include .env

## ?= so anything already set in .env or on the command line wins.
PORT   ?= 4953
DEVICE ?= BlackHole 16ch

.PHONY: build stream devices clean

build:
	swift build -c $(CONFIG)

## Capture and pipe to the snapserver tcp:// source. Ctrl-C to stop.
stream: build
ifndef SERVER
	$(error SERVER is not set. Copy .env.example to .env and set it, or run: make stream SERVER=snapserver.local)
endif
	$(BIN) "$(DEVICE)" | nc $(SERVER) $(PORT)

## Exact device names, as snapcap expects them.
devices:
	@system_profiler SPAudioDataType | grep -E '^ {8}[^ ].*:$$' | sed 's/^ *//;s/:$$//'

clean:
	swift package clean
