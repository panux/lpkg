#!/bin/sh

# Script to remove a package

fail() {
    echo "ERROR: $1" >&2
    if [ -z "$2" ]; then
        exit 1
    fi
    exit "$2"
}

if [ $# -ne 1 ]; then
    echo "Usage: $0 PKGNAME"
    fail "Wrong number of arguments"
fi

if [ ! -z "$ROOTFS" ]; then
    if [ ! -d "$ROOTFS" ]; then
        fail "$ROOTFS does not exist or is not a directory"
    fi
fi

if [ -z "$LPKGDIR" ]; then
    echo "LPKGDIR not set. Assuming $ROOTFS/etc/lpkg.d"
    LPKGDIR="$ROOTFS/etc/lpkg.d"
fi

if [ ! -d "$LPKGDIR" ]; then
    fail "$LPKGDIR does not exist" 2
fi

# Acquire lock
mkdir "$LPKGDIR/lpkg.lock" || fail "Failed to acquire lock"


NAME="$1"
dbd="$LPKGDIR/db/$NAME"

if [ ! -d "$dbd" ]; then
    rm -rf "$LPKGDIR/lpkg.lock"
    fail "$NAME is not installed" 2
fi

scanlists() {
    cd "$LPKGDIR/db"
    for i in $(ls); do
        if [ "$i" != "$NAME" ]; then
            if [ -e "$i/files.list" ]; then
                cat "$i/files.list" || return 3
            fi
        fi
    done
}

tdel=$(scanlists | grep -xFvf - "$dbd/files.list")
if [ $? -gt 1 ]; then
    fail "Error searching for files to delete" 2
fi

if [ -e "$dbd/hook" ]; then
    "$dbd/hook" remove || fail "Removal hook returned error code $?" 3
fi

rm -rf $tdel || fail "Failed to delete files" 3
rm -r "$dbd" || fail "Failed to remove database entry" 3

rm -rf "$LPKGDIR/lpkg.lock"

echo "Successfully removed package $NAME"
