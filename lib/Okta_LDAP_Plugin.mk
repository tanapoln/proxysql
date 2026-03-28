#!/bin/make -f
#
# Build the Okta LDAP Authentication Plugin as a shared library.
#
# Prerequisites:
#   - libldap (OpenLDAP client library)
#     Linux:  apt install libldap2-dev  OR  yum install openldap-devel
#     macOS:  brew install openldap
#   - OpenSSL (already required by ProxySQL)
#
# Usage:
#   make -f lib/Okta_LDAP_Plugin.mk
#
# Output:
#   binaries/proxysql_okta_ldap_auth.so   (Linux)
#   binaries/proxysql_okta_ldap_auth.dylib (macOS)
#

PROXYSQL_PATH := $(shell while [ ! -f ./src/proxysql_global.cpp ]; do cd ..; done; pwd)

include $(PROXYSQL_PATH)/include/makefiles_vars.mk
include $(PROXYSQL_PATH)/include/makefiles_paths.mk

UNAME_S := $(shell uname -s)

# --- Compiler ---
CXX ?= g++
STDCPP := -std=c++17 -DCXX17

# --- Includes ---
PLUGIN_IDIRS := \
	-I$(PROXYSQL_IDIR) \
	-I$(SQLITE3_IDIR) \
	-I$(SSL_IDIR)

# macOS: Homebrew OpenLDAP
ifeq ($(UNAME_S),Darwin)
OPENLDAP_PREFIX := $(shell brew --prefix openldap 2>/dev/null || echo /usr/local/opt/openldap)
PLUGIN_IDIRS += -I$(OPENLDAP_PREFIX)/include
PLUGIN_LDIRS := -L$(OPENLDAP_PREFIX)/lib -L$(SSL_LDIR)
SHARED_EXT := dylib
SHARED_FLAGS := -dynamiclib -undefined dynamic_lookup -install_name @rpath/proxysql_okta_ldap_auth.$(SHARED_EXT)
else
PLUGIN_LDIRS := -L$(SSL_LDIR)
SHARED_EXT := so
SHARED_FLAGS := -shared -Wl,-soname,proxysql_okta_ldap_auth.$(SHARED_EXT) -Wl,--allow-shlib-undefined
endif

# --- Libraries ---
PLUGIN_LIBS := -lldap -llber -lssl -lcrypto -lpthread

# --- Output ---
BINDIR := $(PROXYSQL_PATH)/binaries
TARGET := $(BINDIR)/proxysql_okta_ldap_auth.$(SHARED_EXT)

# --- Source ---
SRCDIR := $(PROXYSQL_PATH)/lib
OBJDIR := $(SRCDIR)/obj

PLUGIN_SRC := $(SRCDIR)/Okta_LDAP_Plugin.cpp
PLUGIN_OBJ := $(OBJDIR)/Okta_LDAP_Plugin.plugin.o

# --- Flags ---
PLUGIN_CXXFLAGS := $(STDCPP) -fPIC -O2 -ggdb -Wall $(PLUGIN_IDIRS)

# --- Targets ---

.PHONY: default clean

default: $(TARGET)

$(BINDIR):
	mkdir -p $(BINDIR)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(PLUGIN_OBJ): $(PLUGIN_SRC) | $(OBJDIR)
	$(CXX) $(PLUGIN_CXXFLAGS) $(CXXFLAGS) -c -o $@ $<

$(TARGET): $(PLUGIN_OBJ) | $(BINDIR)
	$(CXX) $(SHARED_FLAGS) -o $@ $< $(PLUGIN_LDIRS) $(PLUGIN_LIBS)
	@echo ""
	@echo "=== Built: $@ ==="
	@echo ""

clean:
	rm -f $(PLUGIN_OBJ) $(TARGET)
