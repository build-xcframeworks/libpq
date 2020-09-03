# libpq on iOS
A script to compile libpq for iOS 13.7

Instructions:
1. Clone:
```
git clone https://github.com/build-xcframeworks/libpq
cd libpq
```
2. Build:
```
bash libpq.sh
```

The resulting directory "output" will contain three XCFrameworks: libssl.xcframework, libcrypto.xcframework and libpq.xcframework.

libpq-test includes a test project to confirm the frameworks working well.
