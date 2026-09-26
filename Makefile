## Mac side: the menu bar app, plus the snapstream/snapcap CLIs.
## Server side: the relay, cross-compiled here and deployed over ssh.

CONFIG := release
BIN    := $(shell swift build -c $(CONFIG) --show-bin-path)

APP      := build/SnapcastSource.app
CONTENTS := $(APP)/Contents

## Local, untracked settings. Copy .env.example to .env and edit.
##
## `-include` so a missing .env is not an error: `make build` must work in a fresh
## clone. Values are plain `KEY=value` make assignments — do not quote them, or the
## quotes become part of the value.
-include .env

## ?= so anything already set in .env or on the command line wins.
PORT       ?= 4953
DEVICE     ?= BlackHole 16ch
## ssh destination for deploy-relay. Separate from SERVER because an ssh config alias
## (with its own known_hosts entry) is often not the same name as the network host.
SSH_HOST   ?= $(SERVER)

## TCC keys the system-audio-capture grant to the code signature. An ad-hoc signature
## changes on every build, so macOS asks again after each `make app`. A stable Developer
## ID or Apple Development certificate keeps the grant. Falls back to ad-hoc ("-").
DEVELOPER_ID   := $(shell security find-identity -v -p codesigning 2>/dev/null \
                  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
DEVELOPMENT_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
                  | grep "Apple Development:" | head -1 | sed -E 's/.*"(.*)".*/\1/')
SIGN_ID ?= $(if $(strip $(DEVELOPER_ID)),$(DEVELOPER_ID),$(if $(strip $(DEVELOPMENT_ID)),$(DEVELOPMENT_ID),-))

.PHONY: build app run install test relay relay-test deploy-relay stream devices clean

build:
	swift build -c $(CONFIG)

## The menu bar app, as a signed bundle (Info.plist is what makes it menu-bar-only and
## what TCC reads the capture prompt text from).
app:
	swift build -c $(CONFIG) --product SnapcastSource
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS
	cp $(BIN)/SnapcastSource $(CONTENTS)/MacOS/SnapcastSource
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	codesign --force --options runtime --timestamp=none \
		--entitlements Resources/SnapcastSource.entitlements \
		--sign "$(SIGN_ID)" $(APP)
	@echo "signed with: $(SIGN_ID)"

run: app
	-pkill -x SnapcastSource
	open $(APP)

## ~/Applications rather than /Applications: no admin rights needed.
install: app
	-pkill -x SnapcastSource
	mkdir -p $(HOME)/Applications
	rm -rf "$(HOME)/Applications/SnapcastSource.app"
	cp -R $(APP) "$(HOME)/Applications/"
	open "$(HOME)/Applications/SnapcastSource.app"

test:
	swift test
	cd relay && go test -race -count=1 ./...

## Static linux/amd64 binary. CGO off so it runs on the server without any Go install.
relay:
	cd relay && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o ../build/snapcast-relay .

relay-test:
	cd relay && go test -race -count=1 ./...

## Installs the relay as a systemd *user* service on SSH_HOST. See deploy/install-relay.sh.
deploy-relay: relay
ifeq ($(strip $(SSH_HOST)),)
	$(error SSH_HOST is not set. Set it in .env, or run: make deploy-relay SSH_HOST=your-server)
endif
	@# Staged in a private directory, not /tmp: a file at /tmp/snapcast-relay once
	@# collided with the relay's own FIFO directory of the same name.
	ssh $(SSH_HOST) 'mkdir -p .cache/snapcast-relay-install'
	scp build/snapcast-relay deploy/snapcast-relay.service deploy/install-relay.sh $(SSH_HOST):.cache/snapcast-relay-install/
	ssh $(SSH_HOST) 'sh .cache/snapcast-relay-install/install-relay.sh'

## Legacy path: capture a BlackHole device with snapcap and pipe it to the relay.
stream: build
ifndef SERVER
	$(error SERVER is not set. Copy .env.example to .env and set it, or run: make stream SERVER=snapserver.local)
endif
	$(BIN)/snapcap "$(DEVICE)" | nc $(SERVER) $(PORT)

## Exact device names, as snapcap expects them.
devices:
	@system_profiler SPAudioDataType | grep -E '^ {8}[^ ].*:$$' | sed 's/^ *//;s/:$$//'

clean:
	swift package clean
	rm -rf build
