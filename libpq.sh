#!/bin/bash

# edit these version numbers to suit your needs, or define them before running the script

echo "LIBRESSL_BUILD_TARGETS environment variable can be set as a string split by ':' as you would a PATH variable. Ditto LIBRESSL_LINK_TARGETS, LIBPQ_BUILD_TARGETS and LIBPQ_LINK_TARGETS"
# example: 
#   export LIBRESSL_BUILD_TARGETS="simulator_x86_64:catalyst_x86_64:macos_x86_64:ios-arm64e"

IFS=':' read -r -a libressl_build_targets <<< "$LIBRESSL_BUILD_TARGETS"
IFS=':' read -r -a libressl_link_targets <<< "$LIBRESSL_LINK_TARGETS"
IFS=':' read -r -a libpq_build_targets <<< "$LIBPQ_BUILD_TARGETS"
IFS=':' read -r -a libpq_link_targets <<< "$LIBPQ_LINK_TARGETS"

if [ -z "$VERSION" ]
then
  VERSION=11.7 #12.2
fi

if [ -z "$IOS" ]
then
  IOS=13.7 # 14.0
fi

if [ -z "$LIBRESSL" ]
then
  LIBRESSL=3.0.2
fi

if [ -z "$MACOSX" ]
then
  MACOSX=10.15 #11.0
fi

declare -a all_targets=("ios-arm64" "ios-arm64e" "simulator_x86_64" "simulator_x86_64h" "simulator_arm64e" "simulator_arm64" "catalyst_x86_64" "catalyst_arm64" "macos_x86_64" "macos_x86_64h" "macos_arm64")
declare -a old_targets=("simulator_x86_64" "catalyst_x86_64" "macos_x86_64" "ios-arm64e")
declare -a appleSiliconTargets=("simulator_arm64" "simulator_x86_64" "catalyst_x86_64" "catalyst_arm64" "macos_arm64" "macos_x86_64" "ios-arm64e")

if [ -z "$libressl_build_targets" ]
then
  declare -a libressl_build_targets=$all_targets
fi

if [ -z "$libressl_link_targets" ]
then
  declare -a libressl_link_targets=$libressl_build_targets
fi

if [ -z "$libpq_build_targets" ]
then
  declare -a libpq_build_targets=$all_targets
fi

if [ -z "$libpq_link_targets" ]
then
  declare -a libpq_link_targets=$libpq_build_targets
fi



set -e

XCODE=`/usr/bin/xcode-select -p`

# to compile libpq for iOS, we need to use the Xcode SDK by saying -isysroot on the compile line
# there are two SDKs we need to use, the iOS device SDK (arm) and the simulator SDK (x86)
#DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
#SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk

# check to see if the SDK version we selected exists
#if [ ! -e "$SDKROOT" ]
#then
#    echo "The iOS SDK ${IOS} doesn't exist, please edit this file and fix the IOS= variable at the top."
#    exit 1
#fi

# hard clean
#rm -R libressl-?.?.? postgresql-??.? build Fat output

# download LibreSSL
if [ ! -e "libressl-$LIBRESSL" ]
then
    curl -OL "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${LIBRESSL}.tar.gz"
    tar -zxf "libressl-${LIBRESSL}.tar.gz"
fi

# download postgres
if [ ! -e "postgresql-$VERSION.tar.gz" ]
then
    curl -OL "https://ftp.postgresql.org/pub/source/v${VERSION}/postgresql-${VERSION}.tar.gz"
fi

# create a staging directory (we need this for include files later on)
PREFIX=$(pwd)/build/libressl-build    # this is where we build libressl
OUTPUT=$(pwd)/Fat/libressl            # after we build, we put libressls outputs here
LIBPQPREFIX=$(pwd)/build/libpq-build  # this is where we build libpq
LIBPQOUTPUT=$(pwd)/Fat/libpq          # after we build, we put libpqs outputs here
XCFRAMEWORKS=$(pwd)/output/           # this is where we produce the resulting XCFrameworks: libcrypto.xcframework, libssl.xcframework and libpq.xcframework
TESTPROJECT=$(pwd)/libpq-test         # this is the test project where we ensure everything works correctly

mkdir -p $PREFIX
mkdir -p $OUTPUT
mkdir -p $LIBPQPREFIX
mkdir -p $LIBPQOUTPUT
mkdir -p $XCFRAMEWORKS
mkdir -p $TESTPROJECT


echo "Let's output all variables for the sake of the CI"
echo "---"
( set -o posix ; set )
echo "---"
#sleep 30

for target in "${libressl_build_targets[@]}"
do
  mkdir -p $PREFIX/$target;
  mkdir -p $OUTPUT/$target/lib;
  mkdir -p $OUTPUT/$target/include;
done

for target in "${libpq_build_targets[@]}"
do
  mkdir -p $LIBPQPREFIX/$target;
  mkdir -p $LIBPQOUTPUT/$target/lib;
  mkdir -p $LIBPQOUTPUT/$target/include;
done


cd libressl-${LIBRESSL}

# this cleans everything out of the build directory so we can have a clean build
if [ -e "./Makefile" ]
then
  # since we clean before we build, do we still need this??
    make distclean
fi

# some bash'isms
elementIn () { # source https://stackoverflow.com/questions/3685970/check-if-a-bash-array-contains-a-value
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

makeLibreSSL() {
  # only build the files we need (libcrypto, libssl, include files)
  make -C crypto clean all install
  make -C ssl clean all install
  make -C include install
}

moveLibreSSLOutputInPlace() {
  local target=$1
  local output=$2
  cp crypto/.libs/libcrypto.a $output/$target/lib
  cp ssl/.libs/libssl.a $output/$target/lib
  # cp include .... $OUTPUT/$target/include # which one is this?
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

##############################################
##  iOS Simulator x86_64h libssl Compilation
##############################################

target=simulator_x86_64h
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then


  printf "\n\n--> iOS Simulator x86_64h libssl Compilation"
  
  DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

  ./configure --host=x86_64-apple-darwin --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang" \
    CPPFLAGS="-I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch x86_64h -miphoneos-version-min=${IOS} -pipe -no-cpp-precomp -isysroot $SDKROOT" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD=$DEVROOT/usr/bin/ld

  makeLibreSSL
  printf "\n\n--> XX iOS Simulator x86_64h libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

#############################################
##  iOS Simulator x86_64 libssl Compilation
#############################################

target=simulator_x86_64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> iOS Simulator x86_64 libssl Compilation"

  DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

  echo "prefix: $PREFIX/$target"
  echo "SDKROOT: $SDKROOT"
  echo "CPPFLAGS: $CPPFLAGS"
  echo "IOS: $IOS"

  ./configure --host=x86_64-apple-darwin --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang" \
    CPPFLAGS="-I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch x86_64 -miphoneos-version-min=${IOS} -pipe -no-cpp-precomp -isysroot $SDKROOT" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD=$DEVROOT/usr/bin/ld

  makeLibreSSL
  echo -printf "\n\n--> XX iOS Simulator x86_64 libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

#############################################
##  iOS Simulator arm64e libssl Compilation
#############################################

target=simulator_arm64e
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> iOS Simulator arm64e libssl Compilation"

  DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

  ./configure --host=arm-apple-darwin --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang" \
    CPPFLAGS="-I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64e -miphoneos-version-min=${IOS} -pipe -no-cpp-precomp -isysroot $SDKROOT" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD=$DEVROOT/usr/bin/ld

  makeLibreSSL
  printf "\n\n--> XX iOS Simulator arm64e libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

#############################################
##  iOS Simulator arm64 libssl Compilation
#############################################

target=simulator_arm64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> iOS Simulator arm64 libssl Compilation"

  DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

  ./configure --host=arm-apple-darwin --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang" \
    CPPFLAGS="-I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64 -miphoneos-version-min=${IOS} -pipe -no-cpp-precomp -isysroot $SDKROOT" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD=$DEVROOT/usr/bin/ld

  makeLibreSSL
  printf "\n\n--> XX iOS Simulator arm64 libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT
  
fi;


##################################
##  iOS arm64 libssl Compilation
##################################

target=ios-arm64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> iOS arm64 libssl Compilation"

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk

  ./configure --host=arm-apple-darwin --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64 -miphoneos-version-min=${IOS} -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp -D__arm__=1 $CPPFLAGS" \
    LD=$DEVROOT/usr/bin/ld

  makeLibreSSL
  printf "\n\n--> XX iOS arm64 libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

###################################
##  iOS arm64e libssl Compilation
###################################

target=ios-arm64e
if elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> iOS arm64e libssl Compilation"

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk

  ./configure --host=aarch64-apple-darwin19 --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64e -miphoneos-version-min=${IOS} -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp -D__arm__=1 $CPPFLAGS" \
    LD=$DEVROOT/usr/bin/ld

  makeLibreSSL
  printf "\n\n--> XX iOS arm64e libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

##############################################
##  macOS Catalyst x86_64 libssl Compilation
##############################################

target=catalyst_x86_64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> macOS Catalyst x86_64 libssl Compilation"

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

  ./configure --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -target x86_64-apple-ios${IOS}-macabi -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch x86_64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD="/usr/bin/ld"

  makeLibreSSL
  printf "\n\n--> XX macOS Catalyst x86_64 libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

#############################################
##  macOS Catalyst arm64 libssl Compilation
#############################################

target=catalyst_arm64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> macOS Catalyst arm64e libssl Compilation"

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

  ./configure --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -target arm64-apple-ios${IOS}-macabi -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD="/usr/bin/ld"

  makeLibreSSL
  printf "\n\n--> XX macOS Catalyst arm64e libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;


#####################################
##  macOS x86_64 libssl Compilation
#####################################

target=macos_x86_64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> macOS x86_64 libssl Compilation"

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

  ./configure --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch x86_64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD="/usr/bin/clang -target x86_64-apple-darwin"

  makeLibreSSL
  printf "\n\n--> XX macOS x86_64 libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;


######################################
##  macOS x86_64h libssl Compilation
######################################

target=macos_x86_64h
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> macOS x86_64h libssl Compilation"

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

  ./configure --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch x86_64h -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD="/usr/bin/ld"

  makeLibreSSL
  printf "\n\n--> XX macOS x86_64h libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

#####################################
##  macOS arm64 libssl Compilation
#####################################

target=macos_arm64
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> macOS arm64 libssl Compilation"

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

  ./configure --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD="/usr/bin/ld"

  makeLibreSSL
  printf "\n\n--> XX macOS arm64 libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;

# TODO: This one isn't working - use "host" to cross compile
#####################################
##  macOS arm64e libssl Compilation
#####################################

target=macos_arm64e
if needsRebuilding "$target" && elementIn "$target" "${libressl_build_targets[@]}"; then
  
  printf "\n\n--> macOS arm64e libssl Compilation"

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

  ./configure --prefix="$PREFIX/$target" \
    CC="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/" \
    CFLAGS="$CPPFLAGS -arch arm64e -pipe -no-cpp-precomp" \
    CPP="/usr/bin/cpp $CPPFLAGS" \
    LD="/usr/bin/ld -target arm64-apple-darwin"

  makeLibreSSL
  printf "\n\n--> XX macOS arm64e libssl Compilation"
  moveLibreSSLOutputInPlace $target $OUTPUT

fi;


##################################
## Make XCFrameworks for LibreSSL
##################################

XCFRAMEWORK_CMD="xcodebuild -create-xcframework"
for target in "${libressl_link_targets[@]}"
do
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $OUTPUT/$target/lib/libcrypto.a"
  #XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $OUTPUT/$target/lib/libssl.a" # should we merge libcrypto and libssl, or make two separate frameworks. If two, what header files belong to what framework?
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -headers $OUTPUT/$target/include"
done
#XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -output $XCFRAMEWORKS/libressl.xcframework"
XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -output $XCFRAMEWORKS/libcrypto.xcframework"
printf "\n\n--> XCFramework"
echo $XCFRAMEWORK_CMD
rm -R $XCFRAMEWORKS
eval $XCFRAMEWORK_CMD


XCFRAMEWORK_CMD="xcodebuild -create-xcframework"
for target in "${libressl_link_targets[@]}"
do
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -library $OUTPUT/$target/lib/libssl.a"
  XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -headers $OUTPUT/$target/include"
done
XCFRAMEWORK_CMD="$XCFRAMEWORK_CMD -output $XCFRAMEWORKS/libssl.xcframework"
printf "\n\n--> XCFramework"
echo $XCFRAMEWORK_CMD
eval $XCFRAMEWORK_CMD


cd ..


#############################################
##  macOS Catalyst x86_64 libpq Compilation
#############################################

target=catalyst_x86_64
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

    printf "\n\n--> macOS Catalyst x86_64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-ios${IOS}-macabi -isysroot $SDKROOT " \
    CXX="/usr/bin/clang -target x86_64-apple-ios${IOS}-macabi -isysroot $SDKROOT " \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$PREFIX/$target/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

    printf "\n\n--> macOS Catalyst arm64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-ios${IOS}-macabi -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -target arm64-apple-ios${IOS}-macabi -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$PREFIX/simulator/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

    printf "\n\n--> macOS arm64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target arm64-apple -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -target arm64-apple -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

  tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

    printf "\n\n--> macOS arm64e libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target arm64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$PREFIX/$target/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/clang -target arm64-apple-darwin -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

    printf "\n\n--> macOS x86_64 libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CXX="/usr/bin/clang -target x86_64-apple-darwin -isysroot $SDKROOT" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp -L$PREFIX/$target/lib" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/clang -target x86_64-apple-darwin -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/MacOSX.platform/Developer
  SDKROOT=$DEVROOT/SDKs/MacOSX${MACOSX}.sdk

    printf "\n\n--> macOS x86_64h libpq Compilation"

  ./configure --without-readline --with-openssl \
    CC="/usr/bin/clang -target x86_64-apple -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -target x86_64-apple -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CXXFLAGS="$CPPFLAGS -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__x86_64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk

    printf "\n\n--> iOS arm64 libpq Compilation"

  ./configure --host=arm-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

  DEVROOT=$XCODE/Platforms/iPhoneOS.platform/Developer
  SDKROOT=$DEVROOT/SDKs/iPhoneOS${IOS}.sdk

    printf "\n\n--> iOS arm64e libpq Compilation"

  ./configure --host=arm-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
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


# TODO: This one isn't working - something about linking with unknown file format
###########################################
##  iOS Simulator arm64 libpq Compilation
###########################################

target=simulator_arm64
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

    printf "\n\n--> Simulator arm64 libpq Compilation"

  ./configure --host=arm-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -arch arm64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

    printf "\n\n--> Simulator arm64e libpq Compilation"

  ./configure --host=arm-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -arch arm64e -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

    printf "\n\n--> Simulator x86_64 libpq Compilation"

  ./configure --host=x86_64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -arch x86_64 -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
if needsRebuilding "$target" && elementIn "$target" "${libpq_build_targets[@]}"; then

    tar -zxf "postgresql-${VERSION}.tar.gz"
  cd postgresql-${VERSION}
  chmod u+x ./configure

    DEVROOT=$XCODE/Platforms/iPhoneSimulator.platform/Developer
    SDKROOT=$DEVROOT/SDKs/iPhoneSimulator${IOS}.sdk

    printf "\n\n--> Simulator x86_64h libpq Compilation"

  ./configure --host=x86_64-apple-darwin --without-readline --with-openssl \
    CC="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CXX="/usr/bin/clang -isysroot $SDKROOT -L$PREFIX/$target/lib" \
    CPPFLAGS="-fembed-bitcode -I$SDKROOT/usr/include/ -I$PREFIX/$target/include" \
    CFLAGS="$CPPFLAGS -arch x86_64h -pipe -no-cpp-precomp" \
    CPP="/usr/bin/clang -E -D__arm64__=1 $CPPFLAGS -isysroot $SDKROOT" \
    LD="$DEVROOT/usr/bin/ld -L$PREFIX/$target/lib" PG_SYSROOT="$SDKROOT"
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
for target in "${libpq_link_targets[@]}"
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