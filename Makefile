TARGET := iphone:clang:9.3:6.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = Music~iphone

include $(THEOS)/makefiles/common.mk

# Ubuntu clang-18 + kaynaktan derlenmis ld64 (cctools-port)
ADDITIONAL_LDFLAGS += --ld-path=$(THEOS)/toolchain/linux/iphone/bin/ld

TWEAK_NAME = SiraBende
SiraBende_FILES = Tweak.xm
SiraBende_CFLAGS = -fobjc-arc -fno-modules -fno-exceptions -fno-cxx-exceptions -fno-objc-exceptions -Wno-deprecated-declarations -Wno-unused-variable -Wno-deprecated-module-dot-map
sbqctl_CFLAGS = -fno-modules -Wno-deprecated-module-dot-map
SiraBende_FRAMEWORKS = UIKit MediaPlayer QuartzCore

TOOL_NAME = sbqctl
sbqctl_FILES = sbqctl.c
sbqctl_INSTALL_PATH = /usr/bin
sbqctl_CODESIGN_FLAGS = -Ssbqctl.entitlements
sbqctl_FRAMEWORKS = CoreFoundation
sbqctl_LDFLAGS = -lobjc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
