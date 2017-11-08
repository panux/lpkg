#!/bin/sh

fail() {
    echo "ERROR: $1" >&2
    if [ -z "$2" ]; then
        exit 1
    fi
    exit "$2"
}

infoval() {
    (
        . "$1"
        local val="$2"
        eval "echo \$$val"
    ) || return $?
}

if [ $# -ne 1 ]; then
    echo "Usage: $0 PKGFILE"
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

if ! `tar tf $1 &> /dev/null`; then
    fail "$1 is not a valid tar file" 2
fi

# Acquire lock
mkdir "$LPKGDIR/lpkg.lock" || fail "Failed to acquire lock"

echo "Loading pkginfo"
eval "$(tar -xOf $1 ./.pkginfo)"

if [ -z "$NAME" ]; then
    fail "NAME is empty!" 2
fi

dbd="$LPKGDIR/db/$NAME"

tmpdir=$(mktemp -d) || fail "Failed to create temporary directory to extract archive" 2

tar -xf "$1" -C "$tmpdir" || fail "Failed to extract package" 2

fscan() {
    cd "$tmpdir" || return 2
    find $(ls) || return 2
}

fscan > "$tmpdir/.files.list"

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

# check if an old version is installed
if [ -e "$dbd" ]; then
    update=1
    echo "Replacing $NAME-$(infoval "$dbd/pkginfo.sh" VERSION) with $NAME-$VERSION"

    tdel=$(scanlists | grep -xFvf - "$tmpdir/.files.list")
    if [ $? -gt 1 ]; then
        fail "Error searching for files to delete" 2
    fi
else
    update=0
    echo "Installing $NAME-$VERSION"
    mkdir "$dbd" || fail "Failed to create DB directory $dbd" 2
fi

mv "$tmpdir/.files.list" "$dbd/files.list.new" || fail "Error moving file list into $dbd" 2
mv "$tmpdir/.pkginfo" "$dbd/pkginfo.sh.new" || fail "Error moving package info into $dbd" 2

trf() {
    if [ ! -e "$1" ]; then
        if [ ! -L "$1" ]; then
            fail "$1 does not exist" 3
        fi
    fi
    if [ -d "$1" -a ! \( -L "$1" \) ]; then
        if [ ! -d "$ROOTFS/$1" ]; then
            local permcode=$(busybox stat -c "%a" "$1") || fail "Failed to acquire permission code for $PWD/$1" 3
            mkdir -m $permcode "$ROOTFS/$1" || fail "Failed to create directory /$1" 3
        fi
        local i=
        for i in $(ls $1); do
            trf "$1/$i"
        done
    else
        mv -f "$1" "$ROOTFS/$1" || fail "Failed to move $1" 3
    fi
}

mvall() {
    cd "$tmpdir" || fail "Failed to cd into $tmpdir" 2
    for i in $(ls); do
        trf "$i"
    done
}

# move everything in a subshell and pass through error if it occurs
(mvall)
mvcode=$?
if [ $mvcode -gt 0 ]; then
    exit $mvcode
fi

# run install trigger script (if present)
if [ -e "$tmpdir/.oninstall" ]; then
    its=install
    if [ $update -eq 1 ]; then
        its=update
    fi
    "$tmpdir/.oninstall" $its || fail "onInstall script returned error code $?" 3
fi

# delete old files (if applicable)
if [ $update -eq 1 ]; then
    if [ ! -z "$tdel" ]; then
        rm -rf $tdel || fail "Failed to delete old files" 3
    fi
fi

# update package state database
mv -f "$dbd/files.list.new" "$dbd/files.list" || fail "Failed to move files.list.new to files.list" 3
mv -f "$dbd/pkginfo.sh.new" "$dbd/pkginfo.sh" || fail "Failed to move pkginfo.sh.new to pkginfo.sh" 3
if [ -e "$tmpdir/.oninstall" ]; then
    mv -f "$tmpdir/.oninstall" "$dbd/hook" || fail "Failed to move .oninstall to hook" 3
else
    if [ -e "$dbd/hook" ]; then
        rm "$dbd/hook" || fail "Failed to unhook $NAME" 3
    fi
fi

# delete tmpdir and unlock
rm -rf "$tmpdir" "$LPKGDIR/lpkg.lock"

echo "Done installing $NAME!"
