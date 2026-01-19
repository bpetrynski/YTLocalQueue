TARGET := iphone:clang:16.5:14.0

# Build number tracking - must be before include
BUILD_NUMBER_FILE := .build_number
BASE_VERSION := 0.0.1

# Load local environment variables from .env.local if it exists
# Set SIDELOAD_PATH in .env.local to enable copying dylib after build
ifneq ($(wildcard .env.local),)
    SIDELOAD_PATH := $(shell grep -E '^[[:space:]]*SIDELOAD_PATH[[:space:]]*=' .env.local 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*$$//')
endif

# Increment build number
-include $(BUILD_NUMBER_FILE)
ifndef BUILD_NUMBER
BUILD_NUMBER := 0
endif

include $(THEOS)/makefiles/common.mk

# Update build number and control file (not a default target)
.PHONY: update-build-number
update-build-number:
	@if [ ! -f $(BUILD_NUMBER_FILE) ]; then \
		echo "BUILD_NUMBER := 0" > $(BUILD_NUMBER_FILE); \
	fi
	@BUILD_NUMBER=$$(($$(grep BUILD_NUMBER $(BUILD_NUMBER_FILE) | cut -d' ' -f3 || echo 0) + 1)); \
	echo "BUILD_NUMBER := $$BUILD_NUMBER" > $(BUILD_NUMBER_FILE); \
	echo "Build number: $$BUILD_NUMBER"; \
	sed -i '' "s/^Version: .*/Version: $(BASE_VERSION)+build$$BUILD_NUMBER/" control; \
	sed -i '' "s/static NSString \*const kYTLPVersion = @\"[^\"]*\";/static NSString *const kYTLPVersion = @\"$(BASE_VERSION)+build$$BUILD_NUMBER\";/" Settings.xm

# Build a single dlopen-friendly dylib (no Substrate), containing both settings and tweak logic
LIBRARY_NAME := YTLocalQueue

$(LIBRARY_NAME)_FILES := \
    Settings.xm \
    Tweak.xm \
    LocalQueueManager.m \
    LocalQueueViewController.m

$(LIBRARY_NAME)_CFLAGS := \
    -fobjc-arc \
    -Wno-objc-property-no-attribute \
    -I$(THEOS_PROJECT_DIR)/Tweaks \
    -DYTLP_DL_ONLY=1 \
    -DTHEOS_LEAN_AND_MEAN=1

$(LIBRARY_NAME)_FRAMEWORKS := UIKit Foundation MediaPlayer
$(LIBRARY_NAME)_LDFLAGS += -ObjC -Wl,-not_for_dyld_shared_cache -undefined dynamic_lookup -Wl,-undefined,dynamic_lookup
$(LIBRARY_NAME)_INSTALL_PATH = /usr/lib

# For LiveContainer compatibility - no Substrate dependency
LEAN_AND_MEAN = 1

include $(THEOS_MAKE_PATH)/library.mk

# Hook into build: update build number before, copy after
all:: update-build-number
all:: copy-to-sideload

# Copy dylib to sideload path after build (optional via SIDELOAD_PATH env var)  
.PHONY: copy-to-sideload
copy-to-sideload:
	@if [ -n "$(SIDELOAD_PATH)" ] && [ -f $(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib ]; then \
		SIDELOAD_DIR="$(SIDELOAD_PATH)"; \
		if [ -d "$$(dirname "$$SIDELOAD_DIR")" ]; then \
			mkdir -p "$$SIDELOAD_DIR"; \
			cp $(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib "$$SIDELOAD_DIR/"; \
			echo "Copied dylib to $$SIDELOAD_DIR"; \
		else \
			echo "Warning: Sideload directory does not exist: $$(dirname "$$SIDELOAD_DIR")"; \
		fi; \
	fi


