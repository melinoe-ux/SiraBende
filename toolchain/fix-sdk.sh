#!/bin/bash
# iOS 9.3 SDK'da libSystem'in yeniden disa aktardigi ama .tbd'si olmayan sistem kutuphaneleri icin
# bos .tbd tanimlari olusturur (ld64 bunlari ariyor; tweak bu sembolleri kullanmiyor).
SDK=/opt/theos/sdks/iPhoneOS9.3.sdk
S=$SDK/usr/lib/system
ls $S
echo ---
sed -n '1,12p' $S/libkeymgr.tbd
echo ---
for lib in $(grep -h -o '/usr/lib/system/[a-z_0-9]*\.dylib' $SDK/usr/lib/libSystem.tbd | sort -u); do
  base=$(basename $lib .dylib)
  if [ ! -f $S/$base.tbd ]; then
    echo "stub: $base"
    cat > $S/$base.tbd <<EOF
---
archs:           [ armv7, armv7s, arm64 ]
platform:        ios
install-name:    $lib
current-version: 1
compatibility-version: 1
exports:
  - archs:           [ armv7, armv7s, arm64 ]
    symbols:         [ ___sb_stub_$base ]
...
EOF
  fi
done
