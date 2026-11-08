#!/bin/bash
# iOS armv7 toolchain'i kaynaktan kurar (GitHub release indirmesi olmadan, sadece git):
#   apple-libtapi + cctools-port (ld64, lipo, strip...) + ldid; derleyici olarak Ubuntu clang-18.
set -e
export DEBIAN_FRONTEND=noninteractive
P=/opt/cctools
J=$(nproc)
apt-get install -y -qq cmake ninja-build libssl-dev libplist-dev uuid-dev libblocksruntime-dev pkg-config autoconf automake libtool python3 >/dev/null
mkdir -p /opt/src && cd /opt/src

if [ ! -x $P/lib/libtapi.so ] && [ ! -f $P/lib/libtapi.so ]; then
  [ -d apple-libtapi ] || git clone --depth 1 https://github.com/tpoechtrager/apple-libtapi.git
  cd apple-libtapi
  INSTALLPREFIX=$P JOBS=$J ./build.sh
  ./install.sh
  cd ..
fi
echo "== libtapi ok"

if [ ! -f $P/lib/libdispatch.so ]; then
  [ -d apple-libdispatch ] || git clone --depth 1 https://github.com/tpoechtrager/apple-libdispatch.git
  mkdir -p apple-libdispatch/build && cd apple-libdispatch/build
  cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_PREFIX=$P .. >/dev/null
  ninja >/dev/null
  ninja install >/dev/null
  cd ../..
fi
echo "== libdispatch ok"

if [ ! -x $P/bin/arm-apple-darwin11-ld ]; then
  [ -d cctools-port ] || git clone --depth 1 https://github.com/tpoechtrager/cctools-port.git
  cd cctools-port/cctools
  ./configure --prefix=$P --with-libtapi=$P --with-libdispatch=$P --with-libblocksruntime=$P \
    --target=arm-apple-darwin11 >/dev/null
  make -j$J >/dev/null
  make install >/dev/null
  cd ../..
fi
echo "== cctools ok"

if [ ! -x $P/bin/ldid ]; then
  [ -d ldid ] || git clone --depth 1 https://github.com/ProcursusTeam/ldid.git
  cd ldid
  make -j$J >/dev/null
  install -m755 ldid $P/bin/ldid
  cd ..
fi
echo "== ldid ok"

# Theos'un bekledigi isimlerle toolchain klasoru
T=/opt/theos/toolchain/linux/iphone/bin
mkdir -p $T
ln -sf /usr/bin/clang-18 $T/clang
ln -sf /usr/bin/clang++-18 $T/clang++
for t in ld lipo strip libtool otool nm ar ranlib install_name_tool codesign_allocate; do
  [ -x $P/bin/arm-apple-darwin11-$t ] && ln -sf $P/bin/arm-apple-darwin11-$t $T/$t
done
ln -sf $P/bin/ldid $T/ldid
ln -sf /usr/bin/dsymutil-18 $T/dsymutil 2>/dev/null || true
echo "$P/lib" > /etc/ld.so.conf.d/cctools.conf && ldconfig

# clang-18, iOS < 9 hedefinde ARC icin libarclite istiyor; iOS 6 runtime'i ARC'yi zaten
# destekledigi icin bos bir arsiv yeterli.
A=/usr/lib/llvm-18/lib/arc
if [ ! -f $A/libarclite_iphoneos.a ]; then
  mkdir -p $A
  echo 'void __sb_arclite_stub(void){}' > /tmp/arcstub.c
  clang-18 -target armv7-apple-ios6.0 -c /tmp/arcstub.c -o /tmp/arcstub.o
  $P/bin/arm-apple-darwin11-ar rcs $A/libarclite_iphoneos.a /tmp/arcstub.o
fi
grep -q THEOS= /root/.bashrc || echo 'export THEOS=/opt/theos' >> /root/.bashrc
ls -la $T
echo THEOS_KURULDU
