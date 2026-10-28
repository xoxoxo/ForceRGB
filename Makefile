NAME := Rads macOS Mini Toolbox
EXEC := RadsMiniToolbox
BUNDLE_ID := local.radsmacosminitoolbox
APP := $(NAME).app
BIN := $(APP)/Contents/MacOS/$(EXEC)
PREFIX ?= /Applications
SIGN ?= -
# An ad-hoc signature normally pins the bundle's code hash, so every rebuild
# loses its Accessibility permission. Pinning the bundle identifier keeps it.
ifeq ($(SIGN),-)
SIGN_FLAGS := --sign - -r='designated => identifier "$(BUNDLE_ID)"'
else
SIGN_FLAGS := --sign "$(SIGN)"
endif

.PHONY: all run install status clean

# The app name has spaces, which make cannot use as a file target, so the
# build always runs.
all:
	mkdir -p "$(APP)/Contents/MacOS"
	clang -fobjc-arc -O2 -Wall \
		-framework Foundation -framework AppKit -framework IOKit \
		-framework CoreGraphics -framework ApplicationServices \
		-framework ServiceManagement \
		-o "$(BIN)" src/main.m
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force $(SIGN_FLAGS) "$(APP)"

run: all
	open "$(APP)"

install: all
	-pkill -x $(EXEC)
	-pkill -x ForceRGB
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/$(APP)" "$(PREFIX)/ForceRGB.app"
	cp -R "$(APP)" "$(PREFIX)/"
	codesign --force $(SIGN_FLAGS) "$(PREFIX)/$(APP)"
	open "$(PREFIX)/$(APP)"

status: all
	"$(BIN)" --status

clean:
	rm -rf "$(APP)" ForceRGB.app
