# Upstream builds with luz; the Makefile it ships is marked as not intended for upstream Theos.
# The differences are packaging only: without THEOS_PACKAGE_SCHEME the tweak links
# /usr/lib/libprefs.dylib and /Library/Frameworks/CydiaSubstrate.framework, neither of which
# exists on a rootless bootstrap, so the dylib never loads and the tweak looks inert.
#
#   make package                  rootless (the default)
#   make package SCHEME=roothide  roothide
#   make package SCHEME=rootful   rootful
#   make package FINALPACKAGE=1   release build: drops the DEBUG schema, and with it the logging,
#                                 the crash handlers and the navigation trace
#
# Every scheme installs to a different prefix, and the code resolves its paths at runtime through
# jbroot() rather than assuming one; see the note above PLPreferencesDirectory in PLRootList.m.
# Each scheme carries its own package architecture, so the three .debs do not overwrite one
# another in packages/: the rootless and roothide theos modules force iphoneos-arm64 and
# iphoneos-arm64e respectively, and rootful keeps the legacy iphoneos-arm from control.

SCHEME ?= rootless
ifeq ($(filter $(SCHEME),rootless roothide rootful),)
$(error SCHEME must be one of rootless, roothide or rootful -- got '$(SCHEME)')
endif

export ARCHS := arm64 arm64e

ifeq ($(SCHEME),rootful)
export TARGET := iphone:clang:latest:14.0
# prefs.xm branches on this as a plain macro, not as a make variable, so it has to reach the
# compiler; luz defines it, this Makefile has to do it by hand.
export PL_DEFINES = -DROOTLESS=0 -DSIMULATOR=0
# CydiaSubstrate.framework is not shared-cache eligible, and current ld refuses to let an eligible
# dylib link an ineligible one. Rootless and roothide link libsubstrate instead and never hit it.
ADDITIONAL_LDFLAGS += -Wl,-not_for_dyld_shared_cache
else
export THEOS_PACKAGE_SCHEME := $(SCHEME)
export TARGET := iphone:clang:latest:15.0
export PL_DEFINES = -DROOTLESS=1 -DSIMULATOR=0
endif

ifeq ($(SCHEME),roothide)
# jbroot() is declared by roothide.h and implemented in libroothide. Theos links it through clang
# modules, but naming it outright keeps the build working if modules are ever turned off.
ADDITIONAL_LDFLAGS += -lroothide
endif

export THEOS_USE_NEW_ABI=1

# Compile against Xcode's own SDK rather than the copy under $THEOS/sdks: in Apple's SDK
# usr/include/libxml2/libxml is a symlink to ../libxml, while the theos copy has it resolved into
# a second real directory, and swiftc then refuses the build with "redefinition of module
# 'libxml2'". Only PLSwiftString.swift trips over it, but the include sysroot has to be consistent
# across the whole compile. ISYSROOT is the knob theos only defaults when unset; SYSROOT is
# assigned outright.
ISYSROOT := $(shell xcrun --sdk iphoneos --show-sdk-path)

include $(THEOS)/makefiles/common.mk

# Preferences is a private framework with no stub in the current Xcode SDK, so the linker needs
# one from a theos SDK. It is passed as a direct linker input rather than as `-framework
# Preferences` plus a `-F` on that SDK: UIKit re-exports UIKitCore, so a search path into an old
# SDK makes ld resolve UIKitCore from there and every newer symbol goes undefined.
PL_PRIVATE_SDK ?= $(lastword $(sort $(wildcard $(THEOS)/sdks/iPhoneOS1[0-9]*.sdk)))
ifeq ($(PL_PRIVATE_SDK),)
$(error No iPhoneOS 1x SDK found in $(THEOS)/sdks -- install one from github.com/theos/sdks or set PL_PRIVATE_SDK)
endif
PL_PREFERENCES_TBD = $(PL_PRIVATE_SDK)/System/Library/PrivateFrameworks/Preferences.framework/Preferences.tbd

LIBRARY_NAME = libprefs
libprefs_FILES = prefs.xm
libprefs_FRAMEWORKS = UIKit
libprefs_LIBRARIES = substrate
libprefs_CFLAGS = -I. $(PL_DEFINES)
libprefs_LDFLAGS = $(PL_PREFERENCES_TBD)
libprefs_INSTALL_PATH = /usr/lib

TWEAK_NAME = PreferenceLoader
PreferenceLoader_FILES = Tweak.xm PLSwiftMeta.m PLHeap.m PLRootList.m PLCrashLog.m PLSwiftString.swift PLSwiftToggle.swift

# The navigation trace is compiled into DEBUG builds only. logos generates hook registration
# ahead of the C preprocessor, so a %hook cannot be #if'd out of a file that is being built --
# leaving the file out of the target is what keeps it out of a release package.
ifneq ($(findstring DEBUG,$(THEOS_SCHEMA)),)
PreferenceLoader_FILES += PLNavigationTrace.xm
endif
PreferenceLoader_FRAMEWORKS = UIKit
PreferenceLoader_LIBRARIES = prefs
PreferenceLoader_CFLAGS = -I. $(PL_DEFINES)
PreferenceLoader_LDFLAGS = $(PL_PREFERENCES_TBD) -L$(THEOS_OBJ_DIR)

include $(THEOS_MAKE_PATH)/library.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-libprefs-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/usr/include/libprefs$(ECHO_END)
	$(ECHO_NOTHING)cp prefs.h $(THEOS_STAGING_DIR)/usr/include/libprefs/prefs.h$(ECHO_END)

after-stage::
	@find $(THEOS_STAGING_DIR) -iname '*.plist' -exec plutil -convert binary1 {} \;
	@mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceBundles \
	          $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences

after-install::
	install.exec "killall -9 Preferences"
