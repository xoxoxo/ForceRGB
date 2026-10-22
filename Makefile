APP := ForceRGB.app
BIN := $(APP)/Contents/MacOS/ForceRGB
PREFIX ?= /Applications

.PHONY: all run install status clean

all: $(BIN)

$(BIN): src/main.m Info.plist
	mkdir -p $(APP)/Contents/MacOS
	clang -fobjc-arc -O2 -Wall \
		-framework Foundation -framework AppKit -framework IOKit \
		-framework CoreGraphics -framework ServiceManagement \
		-o $(BIN) src/main.m
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: all
	open $(APP)

install: all
	-pkill -x ForceRGB
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/ForceRGB.app"
	cp -R $(APP) "$(PREFIX)/"
	codesign --force --sign - "$(PREFIX)/ForceRGB.app"
	open "$(PREFIX)/ForceRGB.app"

status: all
	$(BIN) --status

clean:
	rm -rf $(APP)
