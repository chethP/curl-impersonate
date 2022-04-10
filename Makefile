# Makefile to build curl-impersonate
# Some Makefile tricks were taken from https://tech.davis-hansson.com/p/make/

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

BROTLI_VERSION := 1.0.9
NSS_VERSION := nss-3.75
NSS_URL := https://ftp.mozilla.org/pub/security/nss/releases/NSS_3_75_RTM/src/nss-3.75-with-nspr-4.32.tar.gz
BORING_SSL_COMMIT := 3a667d10e94186fd503966f5638e134fe9fb4080
NGHTTP2_VERSION := nghttp2-1.46.0
NGHTTP2_URL := https://github.com/nghttp2/nghttp2/releases/download/v1.46.0/nghttp2-1.46.0.tar.bz2
CURL_VERSION := curl-7.81.0

brotli_install_dir := $(abspath brotli-$(BROTLI_VERSION)/out/installed)
brotli_static_libs := $(brotli_install_dir)/lib/libbrotlicommon-static.a $(brotli_install_dir)/lib/libbrotlidec-static.a
nss_install_dir := $(abspath $(NSS_VERSION)/dist/Release)
nss_static_libs := $(nss_install_dir)/lib/libnss_static.a
boringssl_install_dir := $(abspath boringssl/build)
boringssl_static_libs := $(boringssl_install_dir)/lib/libssl.a $(boringssl_install_dir)/lib/libcrypto.a
nghttp2_install_dir := $(abspath $(NGHTTP2_VERSION)/installed)
nghttp2_static_libs := $(nghttp2_install_dir)/lib/libnghttp2.a

# Dependencies needed to compile the Firefox version
firefox_libs := $(brotli_static_libs) $(nss_static_libs) $(nghttp2_static_libs)
# Dependencies needed to compile the Chrome version
chrome_libs := $(brotli_static_libs) $(boringssl_static_libs) $(nghttp2_static_libs)

basedir := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

# Auto-generate Makefile help.
# Borrowed from https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
.PHONY: help
.DEFAULT_GOAL := help

firefox: curl-impersonate-ff ## Build the Firefox version of curl-impersonate
.PHONY: firefox

chrome: curl-impersonate-chrome ## Build the Chrome version of curl-impersonate
.PHONY: chrome

clean: ## Remove build artifacts
	rm -Rf brotli-$(BROTLI_VERSION).tar.gz brotli-$(BROTLI_VERSION)
	rm -Rf $(NSS_VERSION).tar.gz $(NSS_VERSION)
	rm -Rf boringssl.zip boringssl
	rm -Rf $(NGHTTP2_VERSION).tar.bz2 $(NGHTTP2_VERSION)
	rm -Rf $(CURL_VERSION).tar.xz $(CURL_VERSION)
	rm -Rf out

brotli-$(BROTLI_VERSION).tar.gz:
	curl -L "https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}.tar.gz" \
		-o "brotli-${BROTLI_VERSION}.tar.gz"

$(brotli_static_libs): brotli-$(BROTLI_VERSION).tar.gz
	tar xf brotli-$(BROTLI_VERSION).tar.gz
	cd brotli-$(BROTLI_VERSION)
	mkdir -p out
	cd out
	cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=./installed ..
	cmake --build . --config Release --target install


$(NSS_VERSION).tar.gz:
	curl -L -o $(NSS_VERSION).tar.gz $(NSS_URL)

$(nss_static_libs): $(NSS_VERSION).tar.gz
	tar xf $(NSS_VERSION).tar.gz
	cd $(NSS_VERSION)/nss
	./build.sh -o --disable-tests --static


boringssl.zip:
	curl -L https://github.com/google/boringssl/archive/$(BORING_SSL_COMMIT).zip \
		-o boringssl.zip

# Patch boringssl and use a dummy '.patched' file to mark it patched
boringssl/.patched: $(basedir)/chrome/patches/boringssl-*.patch
	unzip -o boringssl.zip
	mv boringssl-$(BORING_SSL_COMMIT) boringssl
	cd boringssl/
	for p in $^; do patch -p1 < $$p; done
	touch .patched

$(boringssl_static_libs): boringssl.zip boringssl/.patched
	mkdir -p $(boringssl_install_dir)
	cd $(boringssl_install_dir)
	cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=on -GNinja ..
	ninja
	# Fix the directory structure so that curl can compile against it.
	# See https://everything.curl.dev/source/build/tls/boringssl
	mkdir -p lib
	ln -sf ../crypto/libcrypto.a lib/libcrypto.a
	ln -sf ../ssl/libssl.a lib/libssl.a
	cp -Rf ../include .


$(NGHTTP2_VERSION).tar.bz2:
	curl -L $(NGHTTP2_URL) -o $(NGHTTP2_VERSION).tar.bz2

# Patch nghttp2 and use a dummy '.patched' file to mark it patched
$(NGHTTP2_VERSION)/.patched: $(basedir)/firefox/patches/libnghttp2-*.patch
	rm -Rf $(NGHTTP2_VERSION)
	tar -xf $(NGHTTP2_VERSION).tar.bz2
	cd $(NGHTTP2_VERSION)
	for p in $^; do patch -p1 < $$p; done
	# Re-generate the configure script
	autoreconf -i && automake && autoconf
	touch .patched

$(nghttp2_static_libs): $(NGHTTP2_VERSION).tar.bz2 $(NGHTTP2_VERSION)/.patched
	cd $(NGHTTP2_VERSION)
	./configure --prefix=$(nghttp2_install_dir) --with-pic
	make MAKEFLAGS=
	make install MAKEFLAGS=

$(CURL_VERSION).tar.xz:
	curl -L "https://curl.se/download/$(CURL_VERSION).tar.xz" \
		-o "$(CURL_VERSION).tar.xz"

# Apply the "Firefox version" patches and mark using a dummy file
$(CURL_VERSION)/.patched-ff: $(basedir)/firefox/patches/curl-*.patch
	rm -Rf $(CURL_VERSION)
	tar -xf $(CURL_VERSION).tar.xz
	cd $(CURL_VERSION)
	for p in $^; do patch -p1 < $$p; done
	# Re-generate the configure script
	autoreconf -fi
	touch .patched-ff
	rm -f .patched-chrome

# Apply the "Chorme version" patches and mark using a dummy file
$(CURL_VERSION)/.patched-chrome: $(basedir)/chrome/patches/curl-*.patch
	rm -Rf $(CURL_VERSION)
	tar -xf $(CURL_VERSION).tar.xz
	cd $(CURL_VERSION)
	for p in $^; do patch -p1 < $$p; done
	# Re-generate the configure script
	autoreconf -fi
	touch .patched-chrome
	rm -f .patched-ff

# This is a small hack that flags that curl was patched and configured in the "firefox" version
$(CURL_VERSION)/.firefox: $(firefox_libs) $(CURL_VERSION).tar.xz $(CURL_VERSION)/.patched-ff
	cd $(CURL_VERSION)
	./configure --enable-static \
				--disable-shared \
				--with-zlib \
				--with-nghttp2=$(nghttp2_install_dir) \
				--with-brotli=$(brotli_install_dir) \
				--with-nss=$(nss_install_dir) \
				USE_CURL_SSLKEYLOGFILE=true \
				CFLAGS="-I$(nss_install_dir)/../public/nss -I$(nss_install_dir)/include/nspr"
	# Remove possible leftovers from a previous compilation
	make clean MAKEFLAGS=
	touch .firefox
	# Remove the Chrome flag if it exists
	rm -f .chrome

# This is a small hack that flags that curl was patched and configured in the "chrome" version
$(CURL_VERSION)/.chrome: $(chrome_libs)	$(CURL_VERSION).tar.xz $(CURL_VERSION)/.patched-chrome
	cd $(CURL_VERSION)
	./configure --enable-static \
				--disable-shared \
				--with-zlib \
				--with-nghttp2=$(nghttp2_install_dir) \
				--with-brotli=$(brotli_install_dir) \
				--with-openssl=$(boringssl_install_dir) \
				USE_CURL_SSLKEYLOGFILE=true \
				LIBS="-pthread" \
				CFLAGS="-I$(boringssl_install_dir)"
	# Remove possible leftovers from a previous compilation
	make clean MAKEFLAGS=
	touch .chrome
	# Remove the Firefox flag if it exists
	rm -f .firefox


out/curl-impersonate-ff: $(CURL_VERSION)/.firefox
	cd $(CURL_VERSION)
	make MAKEFLAGS=
	cd $(CURDIR)
	mkdir -p $(@D)
	cp -f $(CURL_VERSION)/src/curl $@
	strip $@

# Wrapper scripts for the Firefox version (e.g. 'curl_ff98')
ff-wrappers:
	cp -f $(basedir)/firefox/curl_ff* out/
.PHONY: ff-wrappers

curl-impersonate-ff: out/curl-impersonate-ff ff-wrappers
.PHONY: curl-impersonate-ff


out/curl-impersonate-chrome: $(CURL_VERSION)/.chrome
	cd $(CURL_VERSION)
	make MAKEFLAGS=
	cd $(CURDIR)
	mkdir -p $(@D)
	cp -f $(CURL_VERSION)/src/curl $@
	strip $@

# Wrapper scripts for the Chrome version (e.g. 'curl_chrome99')
chrome-wrappers:
	cp -f $(basedir)/chrome/curl_chrome* $(basedir)/chrome/curl_edge* $(basedir)/chrome/curl_safari* out/
.PHONY: chrome-wrappers

curl-impersonate-chrome: out/curl-impersonate-chrome chrome-wrappers
.PHONY: curl-impersonate-chrome
