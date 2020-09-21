#!/bin/bash

# edit these version numbers to suit your needs, or define them before running the script

echo "BUILD_TARGETS environment variable can be set as a string split by ':' as you would a PATH variable. Ditto LINK_TARGETS"
# example: 
#   export BUILD_TARGETS="simulator_x86_64:catalyst_x86_64:macos_x86_64:ios-arm64e"

IFS=':' read -r -a build_targets <<< "$BUILD_TARGETS"
IFS=':' read -r -a link_targets <<< "$LINK_TARGETS"

if [ -z "$VERSION" ]
then
  VERSION=11.7 #12.2
fi

if [ -z "$IOS" ]
then
  IOS=`xcrun -sdk iphoneos --show-sdk-version`
fi

if [ -z "$MIN_IOS_VERSION" ]
then
  MIN_IOS_VERSION=13.0
fi

if [ -z "$LIBRESSL" ]
then
  LIBRESSL=3.0.2
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
  declare -a build_targets=("simulator_x86_64" "catalyst_x86_64" "macos_x86_64" "ios-arm64")
fi

if [ -z "$link_targets" ]
then
  declare -a link_targets=("simulator_x86_64" "catalyst_x86_64" "macos_x86_64" "ios-arm64")
fi

set -e

XCODE=`/usr/bin/xcode-select -p`

# hard clean
#rm -R libressl-?.?.? postgresql-??.? build Fat output

# download LibreSSL
# Download libressl

if [ ! -e "${LIBRESSL}.zip" ]
then
  curl -iL --max-redirs 1 -o ${LIBRESSL}.zip https://github.com/build-xcframeworks/libressl/releases/download/${LIBRESSL}/${LIBRESSL}.zip
  unzip ${LIBRESSL}.zip
fi

# download postgres
if [ ! -e "postgresql-$VERSION.tar.gz" ]
then
    curl -OL "https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.gz"
fi

# create a staging directory (we need this for include files later on)
LIBPQPREFIX=$(pwd)/build/libpq-build  # this is where we build libpq
LIBPQOUTPUT=$(pwd)/Fat/libpq          # after we build, we put libpqs outputs here
XCFRAMEWORKS=$(pwd)/output/           # this is where we produce the resulting XCFrameworks: libcrypto.xcframework, libssl.xcframework and libpq.xcframework
TESTPROJECT=$(pwd)/libpq-test         # this is the test project where we ensure everything works correctly

mkdir -p $LIBPQPREFIX
mkdir -p $LIBPQOUTPUT
mkdir -p $XCFRAMEWORKS
mkdir -p $TESTPROJECT


if [ -e "libressl" ]
then
  rm -R libressl
fi

mkdir -p libressl/ios/lib
cp -R ${LIBRESSL}/libssl.xcframework/ios-arm64/Headers libressl/ios/include
cp -R ${LIBRESSL}/libssl.xcframework/ios-arm64/libssl.a libressl/ios/lib
cp -R ${LIBRESSL}/libcrypto.xcframework/ios-arm64/libcrypto.a libressl/ios/lib

mkdir -p libressl/simulator/lib
cp -R ${LIBRESSL}/libssl.xcframework/*-simulator/Headers libressl/simulator/include
cp -R ${LIBRESSL}/libssl.xcframework/*-simulator/libssl.a libressl/simulator/lib
cp -R ${LIBRESSL}/libcrypto.xcframework/*-simulator/libcrypto.a libressl/simulator/lib

mkdir -p libressl/macos/lib
cp -R ${LIBRESSL}/libssl.xcframework/macos-*/Headers libressl/macos/include
cp -R ${LIBRESSL}/libssl.xcframework/macos-*/libssl.a libressl/macos/lib
cp -R ${LIBRESSL}/libcrypto.xcframework/macos-*/libcrypto.a libressl/macos/lib

mkdir -p libressl/catalyst/lib
cp -R ${LIBRESSL}/libssl.xcframework/*-maccatalyst/Headers libressl/catalyst/include
cp -R ${LIBRESSL}/libssl.xcframework/*-maccatalyst/libssl.a libressl/catalyst/lib
cp -R ${LIBRESSL}/libcrypto.xcframework/*-maccatalyst/libcrypto.a libressl/catalyst/lib


echo "Let's output all variables for the sake of the CI"
echo "---"
( set -o posix ; set )
echo "---"
#sleep 30

for target in "${build_targets[@]}"
do
  mkdir -p $LIBPQPREFIX/$target;
  mkdir -p $LIBPQOUTPUT/$target/lib;
  mkdir -p $LIBPQOUTPUT/$target/include;
done


# some bash'isms

. resolve_path.inc # https://github.com/keen99/shell-functions/tree/master/resolve_path

elementIn () { # source https://stackoverflow.com/questions/3685970/check-if-a-bash-array-contains-a-value
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

needsRebuilding() {
  local target=$1
  test crypto/.libs/libcrypto.a -nt Makefile
  timestampCompare=$?
  if [ $timestampCompare -eq 1 ]; then
    return 0
  else
    arch=`/usr/bin/lipo -archs crypto/.libs/libcrypto.a`
    if [ "$arch" == "$target" ]; then
      return 1
    else
      return 0
    fi
  fi

}

#############################################
##  macOS Catalyst x86_64 libpq Compilation
#############################################

target=catalyst_x86_64
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

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

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-ios${IOS}-macabi -isysroot $SDKROOT " \
    CXX="/usr/bin/clang -target x86_64-apple-ios${IOS}-macabi -isysroot $SDKROOT " \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq V=1
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX macOS Catalyst x86_64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

############################################
##  macOS Catalyst arm64 libpq Compilation
############################################

target=catalyst_arm64
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS Catalyst arm64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-ios${IOS}-macabi -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64-apple-ios${IOS}-macabi -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq V=1
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX macOS Catalyst arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working - something about linking with unknown file format
###################################
##  macOS arm64 libpq Compilation
###################################

target=macos_arm64
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS arm64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target arm64-apple -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target arm64-apple -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq V=1
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX macOS arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working
####################################
##  macOS arm64e libpq Compilation
####################################

target=macos_arm64e
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS arm64e libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/clang -target arm64-apple-darwin -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq V=1
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX macOS arm64e libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

####################################
##  macOS x86_64 libpq Compilation
####################################

target=macos_x86_64
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS x86_64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/clang -target x86_64-apple-darwin -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq V=1
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX macOS x86_64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working
#####################################
##  macOS x86_64h libpq Compilation
#####################################

target=macos_x86_64h
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/macos
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> macOS x86_64h libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -target x86_64-apple -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq V=1
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX macOS x86_64h libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

####################################
##  iOS arm64 libpq Compilation
####################################

target=ios-arm64
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/ios
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> iOS arm64 libpq Compilation"

  ./configure --host=aarch64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/arm64/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX iOS arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

####################################
##  iOS arm64e libpq Compilation
####################################

target=ios-arm64e
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk
  LIBRESSLROOT_RELATIVE=`pwd`/../libressl/ios
  LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> iOS arm64e libpq Compilation"

  ./configure --host=aarch64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch arm64e -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/arm64/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

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
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator arm64 libpq Compilation"
	echo "-L$LIBRESSLROOT/lib"

  ./configure --host=aarch64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include -L$LIBRESSLROOT/lib" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp -L$LIBRESSLROOT/lib" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX Simulator arm64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

# TODO: This one isn't working - something about linking with unknown file format
############################################
##  iOS Simulator arm64e libpq Compilation
############################################

target=simulator_arm64e
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator arm64e libpq Compilation"

  ./configure --host=aarch64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch arm64e -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX Simulator arm64e libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

############################################
##  iOS Simulator x86_64 libpq Compilation
############################################

#TODO: Doesn't configure all right
target=simulator_x86_64
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator x86_64 libpq Compilation"

  ./configure --host=x86_64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch x86_64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  ls src/interfaces/libpq
  find ./|grep libpq.a
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib
  cp src/interfaces/libpq/libpq.a /tmp

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX Simulator x86_64 libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

#############################################
##  iOS Simulator x86_64h libpq Compilation
#############################################

target=simulator_x86_64h
if needsRebuilding "$target" && elementIn "$target" "${build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk
    LIBRESSLROOT_RELATIVE=`pwd`/../libressl/simulator
    LIBRESSLROOT=$(resolve_path ${LIBRESSLROOT_RELATIVE})

    printf "\n\n--> Simulator x86_64h libpq Compilation"

  ./configure --host=x86_64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$LIBRESSLROOT/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$LIBRESSLROOT/include" \
    CFLAGS="$CPPFLAGS -arch x86_64h -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$LIBRESSLROOT/lib" PG_SYSROOT="$SDKROOT"
  make -C src/interfaces/libpq
  echo "--> XYX"
  echo "cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib"
  cp src/interfaces/libpq/libpq.a ${LIBPQOUTPUT}/$target/lib

    # what about the header files? Which ones should we copy?

    printf "\n\n--> XX Simulator x86_64h libpq Compilation"

  cd ..
  rm -R postgresql-${VERSION}

fi;

##################################
## Make XCFrameworks for LibreSSL
##################################

XCFRAMEWORK_CMD="xcodebuild -create-xcframework"
for target in "${link_targets[@]}"
do
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $LIBPQOUTPUT/$target/lib/libpq.a"
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -headers $LIBPQOUTPUT/$target/include"
done
XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -output $XCFRAMEWORKS/libpq.xcframework"
printf "\n\n--> XCFramework libpq"
echo $XCFRAMEWORK_CMD
eval $XCFRAMEWORK_CMD


## Integrate into test project
cp -R $XCFRAMEWORKS/*.xcframework $TESTPROJECT