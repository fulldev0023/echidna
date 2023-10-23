#! /bin/bash

set -eux

source .github/scripts/host.sh

if [ -f $HOME/.local/lib/libff"$EXT" ]; then
  echo "libff exists, exiting..."
  exit 0
fi

if [ -d libff ]; then
  echo "$(pwd)/libff" already exists! Using it instead of re-cloning the repo.
else
  git clone https://github.com/scipr-lab/libff -b v0.2.1 --recursive
fi
cd libff
git checkout v0.2.1
git submodule init && git submodule update

ARGS=("-DCMAKE_INSTALL_PREFIX=$PREFIX" "-DWITH_PROCPS=OFF")
CXXFLAGS=""
if [ "$HOST_OS" = "macOS" ]; then
  OPENSSL_PREFIX=$(brew --prefix openssl)
  export LDFLAGS=-L$OPENSSL_PREFIX/lib
  export CPPFLAGS=-I$OPENSSL_PREFIX/include
  export CXXFLAGS=-I$OPENSSL_PREFIX/include
  ARGS+=("-DOPENSSL_INCLUDE_DIR=$OPENSSL_PREFIX/include/openssl" "-DCURVE=ALT_BN128" "-DCMAKE_INSTALL_NAME_DIR=$PREFIX/lib" "-DOPENSSL_CRYPTO_LIBRARY=$OPENSSL_PREFIX/lib/libcrypto.dylib" "-DOPENSSL_SSL_LIBRARY=$OPENSSL_PREFIX/lib/libssl.dylib")
  sed -i '' 's/STATIC/SHARED/' libff/CMakeLists.txt # Fix GHC segfaults from hell (idk why)
  sed -i '' 's/STATIC/SHARED/' depends/CMakeLists.txt
fi

if [ "$HOST_OS" = "Linux" ] && [ "$(uname -m)" = "aarch64" ]; then
  ARGS+=("-DCURVE=ALT_BN128")
fi

if [ "$HOST_OS" = "Windows" ]; then
  ARGS+=("-G" "Ninja")
  sed -i 's/find_library(GMP_LIBRARY gmp)/find_library(GMP_LIBRARY NAMES libgmp.a)/' CMakeLists.txt
  export CC=/clang64/bin/clang.exe
  export CXX=/clang64/bin/clang++.exe
  export LD=/clang64/bin/lld.exe
fi

mkdir -p build
cd build
CXXFLAGS="-fPIC $CXXFLAGS" cmake "${ARGS[@]}" ..
cmake --build . && cmake --install .
