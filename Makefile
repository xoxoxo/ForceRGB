APP := ForceRGB.app
BIN := $(APP)/Contents/MacOS/ForceRGB

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
	rm -rf /Applications/ForceRGB.app
	cp -R $(APP) /Applications/
	codesign --force --sign - /Applications/ForceRGB.app
	open /Applications/ForceRGB.app

status: all
	$(BIN) --status

clean:
	rm -rf $(APP)
