#!/usr/bin/env bash
# ============================================================================
# build_proton_arm64ec_colab_v1.sh
# Build SENDIRI: Wine basis Valve Proton (ARM64EC) + FEX, untuk Ubuntu glibc.
# Dijalankan di Google Colab (x86_64) -> hasil aarch64 untuk DroidSpaces.
#
# Pin versi:
#   Wine      : ValveSoftware/wine branch proton_11.0 (wine-nya Proton 11.0-1)
#   Toolchain : bylaws/llvm-mingw 20250920 (ucrt-ubuntu-22.04-x86_64)
#   FEX       : FEX-Emu/FEX tag FEX-2611
#   Box64     : ptitSeb/box64 tag v0.4.4 (hanya wowbox64.dll, build sendiri)
#
# Sifat script (pelajaran dari build Turnip):
#   - Per fase ada STAMP: menjalankan ulang script MELANJUTKAN, bukan dari nol.
#   - Jalan di dalam tmux. SSH putus = build tetap jalan, tinggal attach lagi.
#   - Fail-fast di titik yang diketahui rawan, dengan pesan yang jelas.
#
# Pakai:  bash build_proton_arm64ec_colab_v1.sh [fase]
#   fase: deps|toolchain|wine-tools|wine|fex|box64|package|all   (default: all)
#
# VERSI FINAL KONSOLIDASI (2026-11-20): semua perbaikan dari sesi build
# pertama sudah tertanam — sysroot resolver state kosong, LDFLAGS
# --rpath-link, autogen, target tools lengkap + penyembuhan otomatis
# daftar referensi Makefile, locale.nls. Satu perintah dari nol:
#   tmux new -s build   lalu di dalamnya:   bash build.sh all
#
# V2 (2026-11-22): dukungan WAYLAND (winewayland.drv). Di v1 driver ini
# TIDAK ikut ter-build walau libwayland-dev:arm64 sudah ada di sysroot:
# configure Wine mensyaratkan SEKALIGUS wayland-client + wayland-scanner
# + xkbcommon + xkbregistry (pkg-config target) — xkbregistry yang hilang
# (paket terpisah libxkbregistry-dev) membuat configure melewatkan
# drivernya DIAM-DIAM, dan binary wayland-scanner di host (paket
# libwayland-bin, BUKAN bagian libwayland-dev) juga belum terpasang.
# V2 menambahkan keduanya + probe pkg-config di fase deps + gerbang
# verifikasi keras: configure yang masih menolak Wayland = fase gagal
# di tempat, dan sesudah make install keberadaan winewayland.so/.drv
# diperiksa — tidak boleh lagi lolos diam-diam sampai ke HP.
# ============================================================================
set -uo pipefail

# ----------------------------- konfigurasi ---------------------------------
WORK=/content/build-proton-arm64ec
PREFIX=/content/proton-arm64ec
SYSROOT=/content/sysroot-arm64
STAMPS="$WORK/stamps"
TC_DIR=/content/toolchain/llvm-mingw
WINE_BRANCH=proton_11.0
FEX_TAG=FEX-2611
BOX64_TAG=v0.4.4
JOBS=3   # Colab free ~12GB RAM: 3 job aman, jangan nproc penuh (OOM risiko)

mkdir -p "$WORK" "$STAMPS" "$PREFIX"
cd "$WORK"

log()  { echo; echo "=== $* ==="; }
done_stamp() { [ -f "$STAMPS/$1" ]; }
stamp() { touch "$STAMPS/$1"; echo "[OK] fase $1 selesai"; }

# Ekstrak dari Makefile build target semua path yang direferensikan dari
# tree tools (binary host + file data), relatif terhadap tree tools itu.
# Dipakai supaya tree tools membangun PERSIS yang akan diminta build target
# (daftar manual terbukti kurang terus: tools/wine, nls/locale.nls,
# tools/make_xftmpl, ...).
tools_refs() {
  grep -o "$WORK/build-tools/[a-z0-9_/.-]*" "$WORK/build-aarch64/Makefile" \
    | sed "s|$WORK/build-tools/||" | sort -u | tr '\n' ' '
}

# ----------------------------- fase: deps ----------------------------------
fase_deps() {
  done_stamp deps && { echo "deps: sudah, lewati"; return; }
  log "FASE deps — paket host + cross aarch64 + library arm64"
  # Colab = Ubuntu 24.04 amd64. Tambah arsitektur arm64 (repo ports).
  sudo dpkg --add-architecture arm64
  # sources ports untuk arm64
  if ! grep -rqs "ports.ubuntu.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    UBUNTU_CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")
    sudo tee /etc/apt/sources.list.d/arm64-ports.sources >/dev/null <<EOF
Types: deb deb-src
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: $UBUNTU_CODENAME $UBUNTU_CODENAME-updates $UBUNTU_CODENAME-security
Components: main restricted universe multiverse
Architectures: arm64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    # batasi sources bawaan ke amd64 supaya tidak bentrok
    for f in /etc/apt/sources.list.d/ubuntu.sources; do
      [ -f "$f" ] && ! grep -q "^Architectures:" "$f" && \
        sudo sed -i 's/^Components:/Architectures: amd64\nComponents:/' "$f" || true
    done
  fi
  sudo apt-get update -y || { echo "apt update gagal — cek output di atas"; exit 1; }

  # Host build tools + cross compiler aarch64.
  # libwayland-bin WAJIB ada di host: paket inilah yang berisi binary
  # wayland-scanner (alat BUILD yang jalan di mesin host x86_64 untuk
  # mengolah XML protokol Wayland dari source Wine). libwayland-dev
  # TIDAK berisi binary itu — di v1 scanner tidak terpasang.
  # libfreetype-dev HOST juga wajib: configure build tools native
  # (x86_64) menolak jalan tanpa FreeType 64-bit. Di Colab paket ini
  # sudah terpasang dari sananya jadi tidak terasa; di Ubuntu bersih
  # (GitHub runner) tidak ada — run Actions #1 gagal persis di sini
  # (22 Nov 2026).
  sudo apt-get install -y --no-install-recommends \
    build-essential git wget curl xz-utils zip pkg-config python3 \
    flex bison gettext autoconf automake libtool \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    cmake ninja-build libfreetype-dev libwayland-dev libwayland-bin wayland-protocols \
    || { echo "install paket dasar gagal"; exit 1; }
  command -v wayland-scanner >/dev/null 2>&1 || {
    echo "ERROR: wayland-scanner tidak ditemukan di PATH host — winewayland tidak akan ter-build"; exit 1; }

  # Library target aarch64 untuk unix side Wine: JANGAN diinstal via dpkg.
  # apt pernah menukar python host ke arm64 (Exec format error) karena konflik
  # versi multiarch. Cara aman: ambil .deb arm64 dengan resolver BARU yang
  # state-nya kosong (--root + Dir::State/Dir::Cache di folder kerja).
  # Resolver bawaan host TIDAK dipakai: dia melewatkan diam-diam paket
  # Multi-Arch:same yang versi amd64-nya sudah terpasang (kasus nyata:
  # zlib1g-dev, libfreetype6, libdbus-1-3, libgnutls30t64 arm64 hilang,
  # symlink .so menggantung, configure Wine gagal link -lfreetype dsb).
  log "deps — download + ekstrak library arm64 ke $SYSROOT"
  mkdir -p "$WORK/debs" "$SYSROOT" "$WORK/apt-state/lists/partial" "$WORK/apt-cache/archives/partial"
  APT_CROSS="apt-get -o Dir::State=$WORK/apt-state -o Dir::Cache=$WORK/apt-cache -o Dir::State::status=$WORK/apt-state/status"
  touch "$WORK/apt-state/status"
  $APT_CROSS update -y || { echo "apt update (cross) gagal"; exit 1; }
  $APT_CROSS -y --download-only --no-install-recommends install \
    libfreetype-dev:arm64 libfontconfig-dev:arm64 libpng-dev:arm64 \
    libxml2-dev:arm64 libxslt1-dev:arm64 libgnutls28-dev:arm64 \
    libx11-dev:arm64 libxext-dev:arm64 libxrandr-dev:arm64 \
    libxcursor-dev:arm64 libxi-dev:arm64 libxfixes-dev:arm64 \
    libxcomposite-dev:arm64 libxinerama-dev:arm64 libxkbcommon-dev:arm64 \
    libxkbregistry-dev:arm64 \
    libxxf86vm-dev:arm64 \
    ocl-icd-opencl-dev:arm64 \
    libwayland-dev:arm64 libvulkan-dev:arm64 \
    libasound2-dev:arm64 libpulse-dev:arm64 libdbus-1-dev:arm64 \
    libudev-dev:arm64 libusb-1.0-0-dev:arm64 libunwind-dev:arm64 \
    libgstreamer1.0-dev:arm64 libgstreamer-plugins-base1.0-dev:arm64 \
    libkrb5-dev:arm64 libsdl2-dev:arm64 libcups2-dev:arm64 \
    libosmesa6-dev:arm64 libpcap-dev:arm64 libv4l-dev:arm64 \
    zlib1g-dev:arm64 libbz2-dev:arm64 libbrotli-dev:arm64 \
    libharfbuzz-dev:arm64 libglib2.0-dev:arm64 libgraphite2-dev:arm64 \
    libffi-dev:arm64 libpcre2-dev:arm64 libmount-dev:arm64 \
    libtasn1-6-dev:arm64 nettle-dev:arm64 libp11-kit-dev:arm64 \
    libidn2-dev:arm64 libunistring-dev:arm64 \
    || { echo "download library arm64 gagal"; exit 1; }
  # ^ Baris terakhir = penutup rantai .pc (Requires.private): freetype2 butuh
  #   zlib+bzip2+brotli+harfbuzz, gnutls butuh nettle+tasn1+p11-kit, dst.
  #   Tanpa ini pkg-config gagal diam-diam dan configure Wine menolaknya.
  for f in "$WORK"/apt-cache/archives/*.deb; do dpkg-deb -x "$f" "$SYSROOT"; done
  # Fail-fast: symlink .so dev TIDAK boleh menggantung — target runtime-nya
  # (libfreetype.so.6, libz.so.1, libdbus-1.so.3) harus ikut ada di sysroot.
  for so in libfreetype.so.6 libz.so.1 libdbus-1.so.3 libgnutls.so.30 libOpenCL.so.1 \
            libwayland-client.so.0 libxkbcommon.so.0 libxkbregistry.so.0 \
            libX11.so.6 libXext.so.6 libXxf86vm.so.1 libXrandr.so.2 libXfixes.so.3; do
    [ -e "$SYSROOT/usr/lib/aarch64-linux-gnu/$so" ] || {
      echo "ERROR: $so tidak ada di sysroot — resolver cross belum lengkap"; exit 1; }
  done
  # Script linker glibc di sysroot (libc.so, libpthread.so, ...) berisi path
  # absolut /lib/aarch64-linux-gnu/... yang di host TIDAK ada — modul yang
  # flag -L sysroot-nya mendahului LDFLAGS (mis. amd_ags_x64 via -ldrm)
  # gagal link "cannot find /lib/aarch64-linux-gnu/libc.so.6". Arahkan ke
  # glibc cross milik host (memang dipakai semua modul lain lewat urutan
  # -L; versinya sama, Noble 2.39).
  for f in libc.so libpthread.so libm.so libdl.so librt.so libresolv.so libanl.so libutil.so; do
    p="$SYSROOT/usr/lib/aarch64-linux-gnu/$f"
    if [ -f "$p" ] && grep -q "GROUP" "$p" 2>/dev/null; then
      sed -i 's|/usr/lib/aarch64-linux-gnu/|/usr/aarch64-linux-gnu/lib/|g; s|/lib/aarch64-linux-gnu/|/usr/aarch64-linux-gnu/lib/|g; s|/lib/ld-linux-aarch64.so.1|/usr/aarch64-linux-gnu/lib/ld-linux-aarch64.so.1|g' "$p"
      echo "script glibc diperbaiki: $f"
    fi
  done

  # pkg-config cross aarch64: wrapper sendiri yang menunjuk ke sysroot
  # (nama paketnya tidak ada di Noble; pola sama seperti build Turnip).
  printf '#!/bin/sh\nexport PKG_CONFIG_SYSROOT_DIR=%s\nexport PKG_CONFIG_LIBDIR=%s/usr/lib/aarch64-linux-gnu/pkgconfig:%s/usr/share/pkgconfig\nexport PKG_CONFIG_SYSTEM_INCLUDE_PATH=%s/usr/include\nexec pkg-config "$@"\n' \
    "$SYSROOT" "$SYSROOT" "$SYSROOT" \
    | sudo tee /usr/local/bin/aarch64-linux-gnu-pkg-config >/dev/null
  sudo chmod +x /usr/local/bin/aarch64-linux-gnu-pkg-config
  aarch64-linux-gnu-pkg-config --cflags --libs freetype2 >/dev/null 2>&1 || {
    echo "ERROR: rantai .pc freetype2 belum lengkap di sysroot (cek Requires-nya)"; exit 1; }
  # Probe Wayland target: tiga .pc ini yang ditanya configure Wine untuk
  # winewayland (wayland-client, xkbcommon, xkbregistry). Kalau satu saja
  # tidak terbaca pkg-config cross, configure akan melewatkan driver
  # Wayland TANPA error — jadi gagal di sini saja, dengan pesan jelas.
  aarch64-linux-gnu-pkg-config --modversion wayland-client xkbcommon xkbregistry >/dev/null 2>&1 || {
    echo "ERROR: .pc Wayland target belum lengkap di sysroot (wayland-client / xkbcommon / xkbregistry)"; exit 1; }
  # Probe X11 target: pola yang sama — tanpa .pc ini configure melewatkan
  # winex11 diam-diam (terbukti di run GitHub #4, 23 Nov 2026: build
  # "sukses" tapi winex11.so/.drv tidak ada sama sekali di paket).
  aarch64-linux-gnu-pkg-config --modversion x11 xext xxf86vm >/dev/null 2>&1 || {
    echo "ERROR: .pc X11 target belum lengkap di sysroot (x11 / xext / xxf86vm) — winex11 akan dilewatkan configure"; exit 1; }
  echo "deps OK: sysroot arm64 siap, pkg-config membaca freetype2 versi $(aarch64-linux-gnu-pkg-config --modversion freetype2)"
  echo "deps OK: Wayland target siap — wayland-client $(aarch64-linux-gnu-pkg-config --modversion wayland-client), xkbregistry $(aarch64-linux-gnu-pkg-config --modversion xkbregistry), scanner host: $(command -v wayland-scanner)"
  stamp deps
}

# --------------------------- fase: toolchain -------------------------------
fase_toolchain() {
  done_stamp toolchain && { echo "toolchain: sudah, lewati"; return; }
  log "FASE toolchain — bylaws/llvm-mingw 20250920"
  cd "$WORK"
  [ -f llvm-mingw.tar.xz ] || wget -q \
    https://github.com/bylaws/llvm-mingw/releases/download/20250920/llvm-mingw-20250920-ucrt-ubuntu-22.04-x86_64.tar.xz \
    -O llvm-mingw.tar.xz || { echo "download llvm-mingw gagal"; exit 1; }
  mkdir -p /content/toolchain
  tar -xf llvm-mingw.tar.xz -C /content/toolchain
  mv /content/toolchain/llvm-mingw-* /content/toolchain/llvm-mingw 2>/dev/null || true
  # Fail-fast: compiler ARM64EC HARUS ada
  ls "$TC_DIR/bin/arm64ec-w64-mingw32-clang" >/dev/null 2>&1 || {
    echo "ERROR: arm64ec-w64-mingw32-clang tidak ditemukan di $TC_DIR/bin"
    ls "$TC_DIR/bin" | head; exit 1; }
  echo "toolchain OK: $("$TC_DIR/bin/arm64ec-w64-mingw32-clang" --version | head -1)"
  stamp toolchain
}

export PATH="$TC_DIR/bin:$PATH"

# --------------------------- fase: wine-tools ------------------------------
fase_wine_tools() {
  done_stamp wine-tools && { echo "wine-tools: sudah, lewati"; return; }
  log "FASE wine-tools — ambil source Wine Proton + build tools native"
  cd "$WORK"
  if [ ! -d wine-src ]; then
    git clone --depth 1 -b "$WINE_BRANCH" https://github.com/ValveSoftware/wine wine-src \
      || { echo "clone wine gagal"; exit 1; }
  fi
  # Source git Wine TIDAK menyertakan 'configure' jadi (hanya configure.ac
  # + autogen.sh) — hasilkan dulu dengan autogen.sh.
  if [ ! -f wine-src/configure ]; then
    (cd wine-src && ./autogen.sh) || { echo "autogen.sh gagal"; exit 1; }
  fi
  # Patch window.c: field xinput2_rawinput di x11drv.h terlindung
  # #ifdef HAVE_X11_EXTENSIONS_XINPUT2_H, tapi window.c memakainya TANPA
  # guard (kelalaian upstream, hanya muncul di build tanpa XInput2 seperti
  # sysroot kita yang libxi-nya tidak terdeteksi configure). mouse.c sudah
  # menyediakan stub x11drv_xinput2_enable/disable/init untuk build tanpa
  # XInput2, jadi cukup baris assignment-nya saja yang diberi guard.
  WINEX11_WINDOW="$WORK/wine-src/dlls/winex11.drv/window.c"
  if ! grep -B1 "xinput2_rawinput = TRUE" "$WINEX11_WINDOW" | grep -q "ifdef HAVE_X11_EXTENSIONS_XINPUT2_H"; then
    sed -i 's|data->xinput2_rawinput = TRUE;|#ifdef HAVE_X11_EXTENSIONS_XINPUT2_H\n                data->xinput2_rawinput = TRUE;\n#endif|' "$WINEX11_WINDOW"
    echo "[info] patch guard xinput2_rawinput diterapkan ke window.c"
  fi
  # Patch xvidmode.c: SONAME_LIBXXF86VM dan konstanta proto X_XF86VidMode*
  # terdeteksi configure, tapi guard header client-nya
  # (HAVE_X11_EXTENSIONS_XF86VMODE_H) tidak ter-set di setup sysroot kita,
  # sehingga xf86vmode.h tidak pernah di-include dan tipe XF86VidModeGamma
  # tidak dikenal. Paksa include-nya (header ada di sysroot via
  # libxxf86vm-dev). Tanpa reconfigure, tanpa rebuild massal.
  # Guard yang sama juga mengendalikan include + member struct mode_info
  # (XF86VidModeModeInfo) di x11drv.h — paksa di kedua file sekaligus,
  # kalau tidak xvidmode.c memakai member yang tidak dideklarasikan.
  for f in dlls/winex11.drv/xvidmode.c dlls/winex11.drv/x11drv.h; do
    if grep -q "#ifdef HAVE_X11_EXTENSIONS_XF86VMODE_H" "$WORK/wine-src/$f"; then
      sed -i 's|#ifdef HAVE_X11_EXTENSIONS_XF86VMODE_H|#if 1|g' "$WORK/wine-src/$f"
      echo "[info] patch force-include xf86vmode.h diterapkan ke $f"
    fi
  done
  # Patch bus_sdl.c: isi file terkurung #ifdef SONAME_LIBSDL2 (baris 61)
  # sampai #endif (baris 1287), tapi bus_udev.c memanggil
  # is_sdl_ignored_device TANPA guard dan config.h kita tidak punya
  # SONAME_LIBSDL2 (soname SDL2 tidak terdeteksi configure, walau
  # header-nya ketemu) — link winebus.so gagal undefined reference.
  # File ini SUDAH punya cabang #else (stub fungsi bus lain), jadi stub
  # ditambahkan DI DALAM cabang itu, tepat sebelum #endif — JANGAN
  # menambah #else baru, itu error "#else after #else". Tanpa SDL tidak
  # ada device yang diabaikan demi SDL; backend udev/hid tetap jalan.
  WINEBUS_SDL="$WORK/wine-src/dlls/winebus.sys/bus_sdl.c"
  if ! grep -q "stub tanpa SDL2" "$WINEBUS_SDL"; then
    sed -i 's|^#endif /\* SONAME_LIBSDL2 \*/|/* stub tanpa SDL2 */\nBOOL is_sdl_ignored_device(WORD vid, WORD pid)\n{\n    return FALSE;\n}\n#endif /* SONAME_LIBSDL2 */|' "$WINEBUS_SDL"
    echo "[info] patch stub is_sdl_ignored_device diterapkan ke bus_sdl.c"
  fi
  # Patch mouse.c (winex11.drv): pXFixesHideCursor/pXFixesShowCursor
  # dipanggil TANPA guard di fungsi warp pointer, tapi definisi
  # pointer-nya (MAKE_FUNCPTR di x11drv_main.c) terkurung guard —
  # configure kita tidak men-set SONAME_LIBXFIXES maupun
  # HAVE_X11_EXTENSIONS_XFIXES_H walau header+lib XFixes ada lengkap di
  # sysroot, jadi link winex11.so gagal undefined reference. Beri guard
  # SONAME_LIBXFIXES pada dua pemanggilan itu; XWarpPointer (kerja
  # sebenarnya) tidak terpengaruh, yang hilang hanya sembunyi/tampil
  # kursor selama warp (kosmetik). JANGAN mengedit config.h untuk
  # mengaktifkan XFixes beneran — config.h berubah = rebuild massal.
  WINEX11_MOUSE="$WORK/wine-src/dlls/winex11.drv/mouse.c"
  if ! grep -B1 "pXFixesHideCursor( data" "$WINEX11_MOUSE" | grep -q "ifdef SONAME_LIBXFIXES"; then
    sed -i 's|pXFixesHideCursor( data->display, root_window );|#ifdef SONAME_LIBXFIXES\n    pXFixesHideCursor( data->display, root_window );\n#endif|' "$WINEX11_MOUSE"
    sed -i 's|pXFixesShowCursor( data->display, root_window );|#ifdef SONAME_LIBXFIXES\n    pXFixesShowCursor( data->display, root_window );\n#endif|' "$WINEX11_MOUSE"
    echo "[info] patch guard XFixes diterapkan ke mouse.c"
  fi
  # Cek dukungan HODLL di source (titik risiko no.1 — hanya lapor di v1)
  if grep -rqs "HODLL" wine-src/dlls/ntdll/; then
    echo "[info] Source Wine Proton SUDAH mengenal env HODLL (bagus)."
  else
    echo "[info] Source belum mengenal HODLL — emulator akan dipilih lewat"
    echo "       registry Wow64 (jalur bawaan Wine), patch HODLL menyusul bila perlu."
  fi
  mkdir -p build-tools && cd build-tools
  if [ ! -f Makefile ]; then
    ../wine-src/configure --disable-tests --enable-archs=x86_64 \
      --without-x --without-vulkan \
      --without-gstreamer || { echo "configure tools gagal"; exit 1; }
    # JANGAN --without-freetype di sini: sfnt2fon (tool host) membutuhkannya
    # (gerbang SONAME_LIBFREETYPE) untuk mengolah font .fon di akhir build
    # target; tanpa itu build gagal di fonts/*.fon. FreeType yang dipakai
    # tool host adalah freetype host (amd64), bukan yang di sysroot arm64.
  fi
  # Target make = path BINARY-nya. Nama folder saja dianggap make sudah
  # selesai ("Nothing to be done") — itu jebakan yang kena di percobaan awal.
  make -j"$JOBS" tools/widl/widl tools/winebuild/winebuild tools/wrc/wrc \
    tools/wmc/wmc tools/winegcc/winegcc tools/winedump/winedump \
    tools/sfnt2fon/sfnt2fon tools/wine/wine nls/locale.nls || true
  # ^ nls/locale.nls wajib: wrc mencarinya di <tree-tools>/nls/ dan semua
  #   rule .res di build target menjadikannya prasyarat (error bila absen:
  #   "wrc: unable to load locale.nls").
  if [ ! -f tools/widl/widl ] || [ ! -f tools/winebuild/winebuild ]; then
    echo "[info] target per-binary tidak cukup — full make di tree tools"
    make -j"$JOBS" || { echo "make tools gagal"; exit 1; }
  fi
  ls tools/widl/widl tools/winebuild/winebuild >/dev/null 2>&1 || {
    echo "ERROR: wine-tools tidak ter-build. Cek error make di atas."; exit 1; }
  stamp wine-tools
}

# ------------------------------ fase: wine ---------------------------------
fase_wine() {
  done_stamp wine && { echo "wine: sudah, lewati"; return; }
  done_stamp wine-tools || { echo "fase wine-tools belum selesai"; exit 1; }
  log "FASE wine — cross-build Wine Proton ARM64EC (aarch64 glibc)"
  cd "$WORK"
  export PKG_CONFIG=aarch64-linux-gnu-pkg-config
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig"
  # Tanpa ini pkg-config membuang -I/usr/include (dianggap path sistem)
  # SEBELUM menempelkan sysroot, jadi X11_CFLAGS keluar kosong dan header
  # X yang hanya ada di sysroot (XInput2.h, xf86vmode.h) tidak ketemu.
  export PKG_CONFIG_SYSTEM_INCLUDE_PATH="$SYSROOT/usr/include"
  # CPATH: tes header configure berjalan TANPA -I sysroot (bukti dari
  # config.log run v2 di Colab 22 Nov 2026: perintah tesnya polos
  # "aarch64-linux-gnu-gcc -c -g -O2 conftest.c"), jadi makro HAVE_X11_*
  # tidak ter-set dan -I sysroot tidak masuk ke rule compile winex11 —
  # patch force-include xf86vmode.h lalu gagal "file not found" padahal
  # header-nya ADA di sysroot. CPATH memberi jalur include itu ke semua
  # compile sisi unix, tanpa reconfigure dan tanpa rebuild massal
  # (make hanya meng-compile obyek yang belum jadi).
  export CPATH="$SYSROOT/usr/include${CPATH:+:$CPATH}"
  mkdir -p build-aarch64 && cd build-aarch64
  if [ ! -f Makefile ]; then
    # LDFLAGS wajib, dua pelajaran:
    # 1) --rpath-link ke sysroot: tanpa ini ld tidak menemukan library
    #    DT_NEEDED tingkat dua (kasus nyata: libfreetype.so ketemu, tapi
    #    simbol png_*@PNG16_0 undefined karena libpng16 tidak dicari di
    #    direktori -L untuk dependensi tidak langsung).
    # 2) /usr/aarch64-linux-gnu/lib HARUS lebih dulu dari sysroot: sysroot
    #    berisi libc.so arm64 (script linker ber-path absolut /lib/...),
    #    yang bila terpilih membuat tes compiler configure gagal total
    #    ("C compiler cannot create executables"). Libc yang benar untuk
    #    link adalah milik cross-compiler; sysroot hanya untuk library
    #    tambahan (freetype, png, dst).
    # --without-opencl: modul OpenCL paling rapuh di build ini
    # (pernah bermasalah di Colab 20 Nov 2026; di run GitHub #5 header
    # CL/cl.h KETEMU tapi OPENCL_LIBS kosong, jadi link opencl.so mati
    # dengan ratusan undefined reference cl*). Tidak dipakai game DXVK,
    # jadi matikan saja supaya deterministik.
    ../wine-src/configure \
      LDFLAGS="-L/usr/aarch64-linux-gnu/lib -L$SYSROOT/usr/lib/aarch64-linux-gnu -Wl,--rpath-link,$SYSROOT/usr/lib/aarch64-linux-gnu -Wl,--rpath-link,/usr/aarch64-linux-gnu/lib" \
      --host=aarch64-linux-gnu \
      --with-wine-tools="$WORK/build-tools" \
      --enable-archs=arm64ec,aarch64,i386 \
      --with-mingw=clang \
      --with-x \
      --without-opencl \
      --disable-tests \
      --prefix="$PREFIX" \
      || { echo "configure wine gagal — lihat config.log tail di bawah"; \
           tail -30 config.log; exit 1; }
  fi
  # Gerbang Wayland #1: bila file dev Wayland kurang, configure Wine
  # hanya MENCETAK pemberitahuan "Wayland ... won't be supported" di
  # config.log lalu lanjut seolah tidak terjadi apa-apa — persis yang
  # terjadi di v1 (build sukses, driver tidak ada). Tangkap di sini,
  # sebelum make berjam-jam terbuang.
  if grep -q "Wayland.*won't be supported" config.log 2>/dev/null; then
    echo "ERROR: configure MENOLAK driver Wayland (cek baris Wayland di config.log)."
    echo "       Penyebab klasik: libxkbregistry-dev:arm64 atau wayland-scanner host kurang."
    echo "       Fase deps v2 seharusnya menangkapnya lebih dulu — laporkan baris ini."
    exit 1
  fi
  # Gerbang X11 #1: nasib winex11 di run GitHub #4 — configure
  # melewatkannya TANPA pesan gagal, paket jadi Wayland-only. Makefile
  # modul hanya dibuat configure bila drivernya diaktifkan, jadi
  # keberadaan file ini bukti paling langsung.
  [ -f dlls/winex11.drv/Makefile ] || {
    echo "ERROR: winex11.drv TIDAK masuk daftar build (Makefile modul tidak dibuat configure)."
    echo "       Cek config.log untuk baris X11, dan probe pkg-config x11 di fase deps."
    exit 1; }
  # Make bisa berhenti di "No rule to make target '<tree-tools>/...'" bila
  # ada alat host yang belum dibangun di tree tools: ekstrak daftar lengkap
  # referensinya dari Makefile ini, bangun di tree tools, lalu make ulang.
  make -j"$JOBS" || {
    echo "make berhenti — melengkapi alat host dari daftar referensi Makefile..."
    (cd "$WORK/build-tools" && make -j"$JOBS" $(tools_refs)) || true
    make -j"$JOBS" || { echo "make wine gagal — jalankan ulang script untuk resume make"; exit 1; }
  }
  make install || { echo "make install wine gagal"; exit 1; }
  # Layout install Wine 11: loader asli terpasang di lib/wine/aarch64-unix/
  # (wine + wine-preloader) dan bin/wine SEHARUSNYA symlink ke sana — di
  # build ini symlink itu tidak dibuat oleh make install (semua symlink
  # program di bin/ menggantung menunjuk 'wine'), jadi buat sendiri.
  if [ ! -e "$PREFIX/bin/wine" ] && [ -f "$PREFIX/lib/wine/aarch64-unix/wine" ]; then
    ln -s ../lib/wine/aarch64-unix/wine "$PREFIX/bin/wine"
    echo "[info] symlink bin/wine dibuat manual ke loader aarch64-unix"
  fi
  # Verifikasi format (binary aarch64 tidak bisa dijalankan di Colab x86_64)
  file "$PREFIX/lib/wine/aarch64-unix/wine" | grep -q "aarch64" || { echo "ERROR: loader wine bukan aarch64"; exit 1; }
  file "$PREFIX/bin/wine" | grep -q "aarch64" || { echo "ERROR: bin/wine bukan aarch64"; exit 1; }
  ls "$PREFIX/lib/wine/aarch64-windows/ntdll.dll" >/dev/null 2>&1 || {
    echo "ERROR: DLL aarch64-windows tidak ada — build tidak lengkap"; exit 1; }
  # Gerbang Wayland #2: driver Wayland HARUS ada di hasil install, sisi
  # unix (.so) maupun sisi PE (.drv). Tanpa gerbang ini, paket yang
  # sampai di HP bisa terulang seperti v1: sukses tapi tanpa winewayland.
  ls "$PREFIX/lib/wine/aarch64-unix/winewayland.so" >/dev/null 2>&1 || {
    echo "ERROR: winewayland.so TIDAK ada di hasil install — driver Wayland tidak ter-build"; exit 1; }
  ls "$PREFIX/lib/wine/aarch64-windows/winewayland.drv" >/dev/null 2>&1 || {
    echo "ERROR: winewayland.drv TIDAK ada di hasil install — driver Wayland tidak ter-build"; exit 1; }
  ls "$PREFIX/lib/wine/aarch64-unix/winex11.so" >/dev/null 2>&1 || {
    echo "ERROR: winex11.so TIDAK ada di hasil install — driver X11 tidak ter-build"; exit 1; }
  ls "$PREFIX/lib/wine/aarch64-windows/winex11.drv" >/dev/null 2>&1 || {
    echo "ERROR: winex11.drv TIDAK ada di hasil install — driver X11 tidak ter-build"; exit 1; }
  echo "wine OK: ELF aarch64 + DLL PE terpasang di $PREFIX"
  echo "wine OK: winewayland.so + winewayland.drv IKUT ter-build (driver Wayland tersedia)"
  echo "wine OK: winex11.so + winex11.drv IKUT ter-build (driver X11 tersedia)"
  stamp wine
}

# ------------------------------- fase: fex ---------------------------------
fase_fex() {
  done_stamp fex && { echo "fex: sudah, lewati"; return; }
  done_stamp wine || { echo "fase wine belum selesai"; exit 1; }
  log "FASE fex — build FEX $FEX_TAG (arm64ec + wow64)"
  cd "$WORK"
  if [ ! -d fex-src ]; then
    git clone --recursive --depth 1 -b "$FEX_TAG" https://github.com/FEX-Emu/FEX fex-src \
      || { echo "clone FEX gagal"; exit 1; }
  fi
  cd fex-src
  WINEDLLDIR="$PREFIX/lib/wine/aarch64-windows"
  # --- build 1: ARM64EC (emulator x86_64) -> libarm64ecfex.dll
  mkdir -p build-arm64ec && cd build-arm64ec
  cmake -GNinja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=../Data/CMake/toolchain_mingw.cmake \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR="$WINEDLLDIR" \
    -DENABLE_LTO=False -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
    -DBUILD_TESTING=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False .. \
    || { echo "cmake FEX arm64ec gagal"; exit 1; }
  ninja -j"$JOBS" || { echo "ninja FEX arm64ec gagal — jalankan ulang untuk resume"; exit 1; }
  ninja install || { echo "install FEX arm64ec gagal"; exit 1; }
  cd ..
  # --- build 2: WOW64 (emulator x86 32-bit) -> libwow64fex.dll
  mkdir -p build-wow64 && cd build-wow64
  cmake -GNinja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=../Data/CMake/toolchain_mingw.cmake \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR="$WINEDLLDIR" \
    -DENABLE_LTO=False -DMINGW_TRIPLE=aarch64-w64-mingw32 \
    -DBUILD_TESTING=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False .. \
    || { echo "cmake FEX wow64 gagal"; exit 1; }
  ninja -j"$JOBS" || { echo "ninja FEX wow64 gagal — jalankan ulang untuk resume"; exit 1; }
  ninja install || { echo "install FEX wow64 gagal"; exit 1; }
  cd "$WORK"
  # Verifikasi DLL emulator
  for dll in libarm64ecfex.dll libwow64fex.dll; do
    if [ -f "$WINEDLLDIR/$dll" ]; then
      echo "$dll: $(file "$WINEDLLDIR/$dll")"
    else
      echo "ERROR: $dll tidak ditemukan di $WINEDLLDIR"; exit 1
    fi
  done
  stamp fex
}

# ------------------------------ fase: box64 --------------------------------
# Build SENDIRI wowbox64.dll dari source Box64 (bukan ambil dari Hangover).
# DLL ini emulator x86 32-bit alternatif untuk slot Wow64\x86 — terbukti di
# HP 2026-11-23: Limbo 59.9 FPS di wowbox64 vs 3-7 FPS di libwow64fex.
# Slot 64-bit tetap FEX: Box64 belum merilis DLL ARM64EC (di tag v0.4.4
# folder wine/box64ec belum ada; baru muncul di main sesudahnya).
fase_box64() {
  done_stamp box64 && { echo "box64: sudah, lewati"; return; }
  done_stamp fex || { echo "fase fex belum selesai"; exit 1; }
  log "FASE box64 — build Box64 $BOX64_TAG (wowbox64.dll saja)"
  cd "$WORK"
  if [ ! -d box64-src ]; then
    git clone --recursive --depth 1 -b "$BOX64_TAG" https://github.com/ptitSeb/box64 box64-src \
      || { echo "clone Box64 gagal"; exit 1; }
  fi
  cd box64-src
  WINEDLLDIR="$PREFIX/lib/wine/aarch64-windows"
  # Resep resmi dari repo Box64 sendiri: CMake utama dengan -DARM64=ON
  # (menyalakan ARM_DYNAREC) + -DWOW64=ON membuat ExternalProject "wowbox64"
  # yang meng-compile wine/wow64/ memakai wine/toolchain_mingw.cmake
  # (aarch64-w64-mingw32-clang dari llvm-mingw kita; PATH sudah di-export
  # di badan script). Binary Linux Box64-nya TIDAK ikut dibangun — hanya
  # target wowbox64. Compiler aarch64-linux-gnu dari fase deps dipakai
  # CMake utama untuk menyusun daftar source dynarec yang diteruskan ke
  # sub-build wow64.
  mkdir -p build && cd build
  CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ \
  cmake -GNinja -DARM64=ON -DWOW64=ON -DCMAKE_BUILD_TYPE=Release .. \
    || { echo "cmake Box64 gagal"; exit 1; }
  # Gerbang fail-fast: target wowbox64 HARUS sudah ada sebelum build jalan,
  # supaya konfigurasi yang keliru gagal dalam semenit, bukan belakangan.
  ninja -t targets all 2>/dev/null | grep -q '^wowbox64:' || {
    echo "ERROR: target wowbox64 tidak dibuat CMake (WOW64/ARM_DYNAREC tidak aktif)"; exit 1; }
  ninja -j"$JOBS" wowbox64 || { echo "ninja wowbox64 gagal — jalankan ulang untuk resume"; exit 1; }
  WOWDLL=$(find "$PWD" -name 'wowbox64.dll' -type f | head -1)
  [ -n "$WOWDLL" ] || { echo "ERROR: wowbox64.dll tidak ditemukan di hasil build Box64"; exit 1; }
  cp -f "$WOWDLL" "$WINEDLLDIR/wowbox64.dll"
  echo "wowbox64.dll: $(file "$WINEDLLDIR/wowbox64.dll")"
  cd "$WORK"
  stamp box64
}

# ----------------------------- fase: package -------------------------------
fase_package() {
  done_stamp fex || { echo "fase fex belum selesai"; exit 1; }
  done_stamp box64 || { echo "fase box64 belum selesai"; exit 1; }
  log "FASE package — zip hasil build"
  cat > "$PREFIX/README-INSTAL.txt" <<'EOF'
Hasil build sendiri: Wine basis Proton 11.0 (ARM64EC) + FEX 2611 + Box64 v0.4.4 (wowbox64.dll), target Ubuntu glibc aarch64.
Pasang di DroidSpaces: ekstrak ke ~/proton-arm64ec, lalu:
  export PATH=$HOME/proton-arm64ec/bin:$PATH
Pemilih emulator (registry prefix):
  HKLM\Software\Microsoft\Wow64\amd64 = libarm64ecfex.dll  (FEX, 64-bit)
  HKLM\Software\Microsoft\Wow64\x86   = wowbox64.dll       (Box64 build sendiri, 32-bit)
                                      atau libwow64fex.dll (FEX, cadangan 32-bit)
CATATAN wowbox64.dll: selain di lib/wine/aarch64-windows, DLL ini WAJIB
disalin juga ke drive_c/windows/system32 di dalam prefix — loader wow64
mencari DLL emulator non-FEX dari system32 (terbukti 2026-11-23; tanpa itu
gagal load c0000135). Limbo (32-bit) terbukti 59.9 FPS di wowbox64,
3-7 FPS di libwow64fex. Env game: FEX_TSOENABLED=1 FEX_MULTIBLOCK=1.
Driver grafis: winex11 (bawaan, lewat XWayland) + winewayland (BARU di build v2).
Tes Wayland per game dari terminal di dalam sesi Plasma: DISPLAY= wine <game.exe>
JANGAN set registry Graphics=wayland secara permanen: desktop virtual
(winedesktop) tidak bisa jalan di mode wayland murni pada setup ini.
Runtime di container mungkin butuh: sudo apt install libxkbregistry0
EOF
  cd /content
  rm -f Proton-ARM64EC-Custom-Ubuntu.zip
  # WAJIB --symlinks: tanpa flag ini zip mendereferensi symlink bin/wine
  # menjadi salinan file asli di bin/, dan loader lalu mencari ntdll.so
  # di bin/ (jalur /proc/self/exe) alih-alih di lib/wine/aarch64-unix/ —
  # wine gagal start "could not load ntdll.so". Terbukti di HP 2026-11-20.
  zip -qr --symlinks Proton-ARM64EC-Custom-Ubuntu.zip proton-arm64ec
  ls -lh Proton-ARM64EC-Custom-Ubuntu.zip
  # Cadangan otomatis ke Drive bila ter-mount: /content hilang saat sesi
  # berakhir, jadi zip jangan hanya tinggal di sana.
  if [ -d /content/drive/MyDrive ]; then
    cp -f Proton-ARM64EC-Custom-Ubuntu.zip /content/drive/MyDrive/ \
      && echo "Salinan cadangan zip juga disimpan ke Google Drive (MyDrive)."
  fi
  echo
  echo "SELESAI. Download ke HP dari terminal DroidSpaces:"
  echo "  colab download -s <sesi> content/Proton-ARM64EC-Custom-Ubuntu.zip ~/Proton-ARM64EC-Custom-Ubuntu.zip"
  stamp package
}

# --------------------------------- main ------------------------------------
case "${1:-all}" in
  deps)       fase_deps ;;
  toolchain)  fase_toolchain ;;
  wine-tools) fase_wine_tools ;;
  wine)       fase_wine ;;
  fex)        fase_fex ;;
  box64)      fase_box64 ;;
  package)    fase_package ;;
  all)        fase_deps; fase_toolchain; fase_wine_tools; fase_wine; fase_fex; fase_box64; fase_package ;;
  *) echo "fase tidak dikenal: $1"; exit 1 ;;
esac
echo; echo "Script selesai (fase: ${1:-all}). Stamp tersimpan di $STAMPS"
