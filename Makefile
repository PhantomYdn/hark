# Aural build helpers.
#
# Workaround: on machines with Command Line Tools only (no full Xcode),
# Testing.framework and lib_TestingInterop.dylib are not on the default
# search paths, so `swift test` fails with "no such module 'Testing'".
# The flags below point the compiler/linker at the CLT copies; they are
# harmless on machines where full Xcode is installed.
CLT := /Library/Developer/CommandLineTools
TESTING_FLAGS := \
	-Xswiftc -F$(CLT)/Library/Developer/Frameworks \
	-Xlinker -F$(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/usr/lib

.PHONY: build test release clean

build:
	swift build

test:
	swift test $(TESTING_FLAGS)

release:
	swift build -c release

clean:
	swift package clean
