#!/bin/bash
    echo "$0: Checking integrity of script requires the public key"
    echo "$0: for openbcbc@gmail.com. Preparing to Download:"
    echo "$0: Hit Enter to continue, Ctrl+C to cancel"
    read
    gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 0x3310A652
    if [ "$?" != 0 ]; then
      echo "$0: Could not download public key for openbcbc@gmail.com"
      exit 1
    fi
    echo ""
    echo "$0: Verifying signature on SHA256SUMS file"
    gpg --verify SHA256SUMS.gpg SHA256SUMS
    if [ "$?" != 0 ]; then
      echo "$0: Error: SHA256SUMS failed signature check"
      exit 1
    fi
    echo ""
    echo "$0: Verifying signature on MD5SUMS file"
    gpg --verify MD5SUMS.gpg MD5SUMS
    if [ "$?" != 0 ]; then
      echo "$0: Error: MD5SUMS failed signature check"
      exit 1
    fi
    echo ""
    echo "$0: Verifying SHA256 checksums"
    sha256sum --check SHA256SUMS
    if [ "$?" != 0 ]; then
      echo "$0: Error: failed SHA256 checksums"
      exit 1
    fi
    echo ""
    echo "$0: Verifying MD5 checksums"
    md5sum --check MD5SUMS
    if [ "$?" != 0 ]; then
      echo "$0: Error: failed MD5 checksums"
      exit 1
    fi
    exit 0

