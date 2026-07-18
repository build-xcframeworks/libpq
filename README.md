# libpq on Apple platforms
A script to compile PostgreSQL 18.4 libpq with LibreSSL for Apple platforms.

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
