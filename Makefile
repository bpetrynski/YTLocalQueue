TARGET := iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# Build a single dlopen-friendly dylib (no Substrate), containing both settings and tweak logic
LIBRARY_NAME := YTLocalQueue

$(LIBRARY_NAME)_FILES := \
    Settings.xm \
    Tweak.xm \
    LocalQueueManager.m \
    LocalQueueViewController.m \
    AutoAdvanceController.m

$(LIBRARY_NAME)_CFLAGS := \
    -fobjc-arc \
    -Wno-objc-property-no-attribute \
    -I$(THEOS_PROJECT_DIR)/Tweaks \
    -DYTLP_DL_ONLY=1 \
    -DTHEOS_LEAN_AND_MEAN=1

$(LIBRARY_NAME)_FRAMEWORKS := UIKit Foundation AVFoundation
$(LIBRARY_NAME)_LDFLAGS += -ObjC -Wl,-not_for_dyld_shared_cache -undefined dynamic_lookup -Wl,-undefined,dynamic_lookup
$(LIBRARY_NAME)_INSTALL_PATH = /usr/lib

# For LiveContainer compatibility - no Substrate dependency
LEAN_AND_MEAN = 1

include $(THEOS_MAKE_PATH)/library.mk


