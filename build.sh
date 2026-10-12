#!/bin/sh
# Build ImeIndicator.exe on Linux (Debian/Ubuntu):
#   sudo apt install nasm binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev zip
# (the resource step needs a C preprocessor: the host "cpp" is used)
set -eu
cd "$(dirname "$0")"
LIBDIR=${MINGW_LIBDIR:-/usr/x86_64-w64-mingw32/lib}
mkdir -p build

nasm -f win64 -Werror -o build/ime_indicator.obj ime_indicator.asm

( cd res && x86_64-w64-mingw32-windres \
    --preprocessor=cpp --preprocessor-arg=-E --preprocessor-arg=-xc \
    --preprocessor-arg=-DRC_INVOKED \
    -O coff -i app.rc -o ../build/app_res.o )

x86_64-w64-mingw32-ld -o ImeIndicator.exe \
    --subsystem windows:6.1 -e start \
    --dynamicbase --nxcompat --high-entropy-va --enable-reloc-section \
    -s --file-alignment 512 --section-alignment 4096 \
    build/ime_indicator.obj build/app_res.o \
    -L"$LIBDIR" -lkernel32 -luser32 -lgdi32 -limm32 -lshell32 -lole32 -loleacc

python3 tools/verify_pe.py ImeIndicator.exe
echo "built: $(pwd)/ImeIndicator.exe ($(stat -c %s ImeIndicator.exe) bytes)"

if [ "${1:-}" = "zip" ] || [ "${1:-}" = "dist" ]; then
    rm -f ImeIndicator.zip
    zip -q -X ImeIndicator.zip ImeIndicator.exe README.md ime_indicator.asm build.sh \
        res/app.rc res/app.manifest res/app.ico res/make_icon.py tools/verify_pe.py
    echo "packed: $(pwd)/ImeIndicator.zip"
fi
