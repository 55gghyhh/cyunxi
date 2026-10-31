TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = XCameraPro XCamera

include $(THEOS)/makefiles/common.mk

# 改这个就必须同步改下面三个前缀，否则 _CFLAGS（-fobjc-arc）不生效，
# 会在 __weak 处报 "cannot create __weak reference in file using manual reference counting"
TWEAK_NAME = KAlertLog

KAlertLog_FILES = Tweak.m KLStore.m KLNetLog.m KLViewer.m KLPanel.m
KAlertLog_CFLAGS = -fobjc-arc -fblocks -Wall -Wno-unused-parameter -Wno-deprecated-declarations
KAlertLog_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
