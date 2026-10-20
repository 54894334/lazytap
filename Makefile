TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LazyTap
LazyTap_FILES = src/LTMain.m src/LTHost.m src/LTHID.m src/LTUITouch.m src/LTConfig.m src/LTUI.m
LazyTap_CFLAGS = -fobjc-arc -I src -Wno-deprecated-declarations -Wno-unused-function -Wno-objc-method-access
LazyTap_FRAMEWORKS = UIKit Foundation QuartzCore AudioToolbox WebKit
LazyTap_LDFLAGS = -undefined dynamic_lookup
# 把 HID 权限签进 dylib（宿主本身没有这条权限时仍然无效，仅在选择 HID 通道时需要）
LazyTap_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
