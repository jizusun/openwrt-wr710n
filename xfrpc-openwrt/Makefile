include $(TOPDIR)/rules.mk

PKG_NAME:=xfrpc
PKG_VERSION:=4.05.866
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/liudf0716/xfrpc.git
PKG_SOURCE_VERSION:=3d96ba212b643909abb696fe0e335926105642f3
PKG_SOURCE_DATE:=2025-12-09
PKG_MIRROR_HASH:=skip

PKG_BUILD_DEPENDS:=cmake/host

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/xfrpc
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight frp client in C
  URL:=https://github.com/liudf0716/xfrpc
  DEPENDS:=+libevent2 +libjson-c +zlib +libopenssl
endef

define Package/xfrpc/description
  A lightweight frp client written in C for OpenWrt and IoT devices.
  Supports tcp, tcpmux, http, https, socks5 proxy types.
endef

CMAKE_OPTIONS += \
	-DDEBUG=OFF \
	-DENABLE_SANITIZER=OFF \
	-DTHIRDPARTY_STATIC_BUILD=OFF

# xfrpc uses -Werror; relax format warnings for musl/MIPS time_t mismatch
TARGET_CFLAGS += -Wno-error=format=

define Package/xfrpc/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/xfrpc $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/xfrpc
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/xfrpc_min.ini $(1)/etc/xfrpc/xfrpc.ini
endef

$(eval $(call BuildPackage,xfrpc))
