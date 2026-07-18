#!/bin/bash

# edit these version numbers to suit your needs, or define them before running the script

echo "BUILD_TARGETS environment variable can be set as a string split by ':' as you would a PATH variable. Ditto LINK_TARGETS"
# example: 
#   export BUILD_TARGETS="simulator_x86_64:catalyst_x86_64:macos_x86_64:ios-arm64e"

IFS=':' read -r -a build_targets <<< "$BUILD_TARGETS"
IFS=':' read -r -a link_targets <<< "$LINK_TARGETS"

if [ -z "$VERSION" ]
then
  VERSION=18.4
fi

if [ -z "$IOS" ]
then
  IOS=`xcrun -sdk iphoneos --show-sdk-version`
fi

if [ -z "$MIN_IOS_VERSION" ]
then
  MIN_IOS_VERSION=13.0
fi

if [ -z "$MIN_CATALYST_VERSION" ]
then
  MIN_CATALYST_VERSION=13.1
fi

if [ -z "$MACOSX" ]
then
  MACOSX=`xcrun --sdk macosx --show-sdk-version|cut -d '.' -f 1-2`
fi

declare -a all_targets=("ios-arm64" "ios-arm64e" "simulator_x86_64" "simulator_x86_64h" "simulator_arm64e" "simulator_arm64" "catalyst_x86_64" "catalyst_arm64" "macos_x86_64" "macos_x86_64h" "macos_arm64")
declare -a old_targets=("simulator_x86_64" "catalyst_x86_64" "macos_x86_64" "ios-arm64e")
declare -a appleSiliconTargets=("simulator_arm64" "simulator_x86_64" "catalyst_x86_64" "catalyst_arm64" "macos_arm64" "macos_x86_64" "ios-arm64e")

if [ -z "$build_targets" ]
then
  declare -a build_targets=("simulator_arm64" "catalyst_x86_64" "catalyst_arm64" "macos_x86_64" "macos_arm64" "ios-arm64")
fi

if [ -z "$link_targets" ]
then
  declare -a link_targets=("simulator_arm64" "catalyst_x86_64" "catalyst_arm64" "macos_x86_64" "macos_arm64" "ios-arm64")
fi

set -e

# Do not let host package-manager flags leak into cross-compilation commands.
unset CPPFLAGS CFLAGS CXXFLAGS

XCODE=`/usr/bin/xcode-select -p`

# Build LibreSSL from the requested branch. Consumer pull requests use master;
# LIBRESSL_REF can point at an update branch while validating it.
if [ -z "$LIBRESSL_OUTPUT_DIR" ]
then
  LIBRESSL_REF=${LIBRESSL_REF:-master}
  git clone --depth 1 --branch "$LIBRESSL_REF" https://github.com/build-xcframeworks/libressl.git libressl-source
  (
    cd libressl-source
    bash libressl.sh
  )
  LIBRESSL_OUTPUT_DIR=$(pwd)/libressl-source/output
fi


# download postgres
if [ ! -e "postgresql-$VERSION.tar.gz" ]
then
    curl -OL "https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.gz"
fi

# create a staging directory (we need this for include files later on)
PREFIX=$(pwd)/build/libpq-build  # this is where we build libpq
OUTPUT=$(pwd)/Fat/libpq          # after we build, we put libpqs outputs here
XCFRAMEWORKS=$(pwd)/output/           # this is where we produce the resulting XCFrameworks: libcrypto.xcframework, libssl.xcframework and libpq.xcframework
TESTPROJECT=$(pwd)/libpq-test         # this is the test project where we ensure everything works correctly

mkdir -p $PREFIX
mkdir -p $OUTPUT
mkdir -p $XCFRAMEWORKS
mkdir -p $TESTPROJECT


if [ -e "libressl" ]
then
  rm -R libressl
fi

mkdir -p libressl/ios/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/ios-arm64/Headers" libressl/ios/include
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/ios-arm64/libssl.a" libressl/ios/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libcrypto.xcframework/ios-arm64/libcrypto.a" libressl/ios/lib

mkdir -p libressl/simulator/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/ios-arm64-simulator/Headers" libressl/simulator/include
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/ios-arm64-simulator/libssl.a" libressl/simulator/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libcrypto.xcframework/ios-arm64-simulator/libcrypto.a" libressl/simulator/lib

mkdir -p libressl/macos/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/macos-arm64_x86_64/Headers" libressl/macos/include
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/macos-arm64_x86_64/libssl.a" libressl/macos/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libcrypto.xcframework/macos-arm64_x86_64/libcrypto.a" libressl/macos/lib

mkdir -p libressl/catalyst/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/ios-arm64_x86_64-maccatalyst/Headers" libressl/catalyst/include
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework/ios-arm64_x86_64-maccatalyst/libssl.a" libressl/catalyst/lib
cp -R "$LIBRESSL_OUTPUT_DIR/libcrypto.xcframework/ios-arm64_x86_64-maccatalyst/libcrypto.a" libressl/catalyst/lib


echo "Let's output all variables for the sake of the CI"
echo "---"
( set -o posix ; set )
echo "---"

for target in "${build_targets[@]}"
do
  mkdir -p $PREFIX/$target;
  mkdir -p $OUTPUT/$target/lib;
  mkdir -p $OUTPUT/$target/include;
done


# some bash'isms

. resolve_path.inc # https://github.com/keen99/shell-functions/tree/master/resolve_path

elementIn () { # source https://stackoverflow.com/questions/3685970/check-if-a-bash-array-contains-a-value
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

copyToOutput() {
  local target=$1
  local OUTPUT=$2
  /usr/bin/libtool -static -o "${OUTPUT}/$target/lib/libpq.a" \
    src/interfaces/libpq/libpq.a src/common/libpgcommon_shlib.a src/port/libpgport_shlib.a
  cp src/include/postgres_ext.h ${OUTPUT}/$target/include
  cp src/interfaces/libpq/libpq-fe.h ${OUTPUT}/$target/include
  cp src/include/pg_config.h ${OUTPUT}/$target/include

}

#############################################
##  macOS Catalyst x86_64 libpq Compilation
#############################################

target=catalyst_x86_64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  echo `pwd`
  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/catalyst
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})
  echo ${LIBRESSLROOT}
  ls ${LIBRESSLROOT}

    printf "\n\n--> macOS Catalyst x86_64 libpq Compilation"

  ./configure --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-ios${MIN_CATALYST_VERSION}-macabi -isysroot $SDKROOT " \
    CXX="/usr/bin/clang -target x86_64-apple-ios${MIN_CATALYST_VERSION}-macabi -isysroot $SDKROOT " \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a V=1

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX macOS Catalyst x86_64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

############################################
##  macOS Catalyst arm64 libpq Compilation
############################################

target=catalyst_arm64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/catalyst
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

  printf "\n\n--> macOS Catalyst arm64 libpq Compilation"

  ./configure --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-ios${MIN_CATALYST_VERSION}-macabi -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64-apple-ios${MIN_CATALYST_VERSION}-macabi -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a V=1

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX macOS Catalyst arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working - something about linking with unknown file format
###################################
##  macOS arm64 libpq Compilation
###################################

target=macos_arm64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

  printf "\n\n--> macOS arm64 libpq Compilation"

  ./configure --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-macos11.0 -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64-apple-macos11.0 -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a V=1

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX macOS arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working
####################################
##  macOS arm64e libpq Compilation
####################################

target=macos_arm64e
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

  printf "\n\n--> macOS arm64e libpq Compilation"

  ./configure --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/clang -target arm64-apple-darwin -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a V=1

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX macOS arm64e libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

####################################
##  macOS x86_64 libpq Compilation
####################################

target=macos_x86_64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS x86_64 libpq Compilation"

  ./configure --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/clang -target x86_64-apple-darwin -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a V=1

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX macOS x86_64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working
#####################################
##  macOS x86_64h libpq Compilation
#####################################

target=macos_x86_64h
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS x86_64h libpq Compilation"

  ./configure --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target x86_64-apple -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a V=1

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX macOS x86_64h libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

####################################
##  iOS arm64 libpq Compilation
####################################

target=ios-arm64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/ios
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> iOS arm64 libpq Compilation"

  ./configure --host=aarch64-apple-darwin --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-ios${MIN_IOS_VERSION} -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64-apple-ios${MIN_IOS_VERSION} -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/arm64/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX iOS arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

####################################
##  iOS arm64e libpq Compilation
####################################

target=ios-arm64e
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/ios
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> iOS arm64e libpq Compilation"

  ./configure --host=aarch64-apple-darwin --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64e-apple-ios${MIN_IOS_VERSION} -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64e-apple-ios${MIN_IOS_VERSION} -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch arm64e -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/arm64/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX iOS arm64e libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;


# TODO: This one isn't working, even though I cannot see that libcrypto would be built for iOS
# ld: building for iOS Simulator, but linking in dylib file (./build/libressl-build/simulator_arm64/lib/libcrypto.dylib) built for iOS
###########################################
##  iOS Simulator arm64 libpq Compilation
###########################################

target=simulator_arm64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator arm64 libpq Compilation"
	echo "-L$LIBRESSLROOT/lib"

  ./configure --host=aarch64-apple-darwin --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target arm64-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include -L$LIBRESSLROOT/lib" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX Simulator arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working - something about linking with unknown file format
############################################
##  iOS Simulator arm64e libpq Compilation
############################################

target=simulator_arm64e
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator arm64e libpq Compilation"

  ./configure --host=aarch64-apple-darwin --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target arm64e-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64e-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch arm64e -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX Simulator arm64e libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

############################################
##  iOS Simulator x86_64 libpq Compilation
############################################

#TODO: Doesn't configure all right
target=simulator_x86_64
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator x86_64 libpq Compilation"

  ./configure --host=x86_64-apple-darwin --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target x86_64-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch x86_64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX Simulator x86_64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

#############################################
##  iOS Simulator x86_64h libpq Compilation
#############################################

target=simulator_x86_64h
if elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator x86_64h libpq Compilation"

  ./configure --host=x86_64-apple-darwin --without-readline --without-icu --with-openssl \
    CC="/usr/bin/clang -target x86_64h-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target x86_64h-apple-ios${MIN_IOS_VERSION}-simulator -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch x86_64h -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq libpq.a

  copyToOutput $target ${OUTPUT}

  printf "\n\n--> XX Simulator x86_64h libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

##################################
## Make XCFrameworks for LibreSSL
##################################

XCFRAMEWORK_CMD="xcodebuild -create-xcframework"

if elementIn "catalyst_x86_64" "${link_targets[@]}" && elementIn "catalyst_arm64" "${link_targets[@]}"; then
  mkdir -p "$OUTPUT/catalyst_universal/lib" "$OUTPUT/catalyst_universal/include"
  /usr/bin/lipo -create "$OUTPUT/catalyst_x86_64/lib/libpq.a" "$OUTPUT/catalyst_arm64/lib/libpq.a" -output "$OUTPUT/catalyst_universal/lib/libpq.a"
  cp -R "$OUTPUT/catalyst_arm64/include/." "$OUTPUT/catalyst_universal/include"
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $OUTPUT/catalyst_universal/lib/libpq.a -headers $OUTPUT/catalyst_universal/include"
fi

if elementIn "macos_x86_64" "${link_targets[@]}" && elementIn "macos_arm64" "${link_targets[@]}"; then
  mkdir -p "$OUTPUT/macos_universal/lib" "$OUTPUT/macos_universal/include"
  /usr/bin/lipo -create "$OUTPUT/macos_x86_64/lib/libpq.a" "$OUTPUT/macos_arm64/lib/libpq.a" -output "$OUTPUT/macos_universal/lib/libpq.a"
  cp -R "$OUTPUT/macos_arm64/include/." "$OUTPUT/macos_universal/include"
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $OUTPUT/macos_universal/lib/libpq.a -headers $OUTPUT/macos_universal/include"
fi

for target in "${link_targets[@]}"
do
  if [[ "$target" == catalyst_* ]] && elementIn "catalyst_x86_64" "${link_targets[@]}" && elementIn "catalyst_arm64" "${link_targets[@]}"; then
    continue
  fi
  if [[ "$target" == macos_* ]] && elementIn "macos_x86_64" "${link_targets[@]}" && elementIn "macos_arm64" "${link_targets[@]}"; then
    continue
  fi
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $OUTPUT/$target/lib/libpq.a"
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -headers $OUTPUT/$target/include"
done
XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -output $XCFRAMEWORKS/libpq.xcframework"
printf "\n\n--> XCFramework libpq"
echo $XCFRAMEWORK_CMD
eval $XCFRAMEWORK_CMD

# Include the LibreSSL dependencies promised by the README and referenced by
# the test project. Remove stale copies first so rerunning the build cannot
# leave slices from an older LibreSSL build behind.
rm -R -f "$XCFRAMEWORKS/libssl.xcframework" "$XCFRAMEWORKS/libcrypto.xcframework"
cp -R "$LIBRESSL_OUTPUT_DIR/libssl.xcframework" "$XCFRAMEWORKS/"
cp -R "$LIBRESSL_OUTPUT_DIR/libcrypto.xcframework" "$XCFRAMEWORKS/"

# Both LibreSSL libraries contain the same header tree. Keep the headers on
# libcrypto so Xcode does not generate duplicate ProcessXCFramework outputs.
for headers in "$XCFRAMEWORKS"/libssl.xcframework/*/Headers
do
  rm -R "$headers"
  mkdir -p "$headers"
done

## Integrate into test project
rm -R -f \
  "$TESTPROJECT/libpq.xcframework" \
  "$TESTPROJECT/libssl.xcframework" \
  "$TESTPROJECT/libcrypto.xcframework"
cp -R "$XCFRAMEWORKS"/*.xcframework "$TESTPROJECT"
