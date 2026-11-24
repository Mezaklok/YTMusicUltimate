ARCHS = arm64
TARGET = iphone:clang:16.5:13.0
INSTALL_TARGET_PROCESSES = YouTubeMusic

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTMOfflineStabilityFix
YTMOfflineStabilityFix_FILES = Tweak.xm
YTMOfflineStabilityFix_CFLAGS = -fobjc-arc
YTMOfflineStabilityFix_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

