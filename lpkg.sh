#!/bin/sh

fail() {
    echo "ERROR: $1" >&2
    if [ -z "$2" ]; then
        exit 1
    fi
    exit "$2"
}

fetch() {
    local fetcher
    if [ -z "$bootstrap" ]; then
        fetcher=$(ls "$LPKGDIR/fetchers" | sort -nr | head -n 1)
        # turn into a complete path
        fetcher="$LPKGDIR/fetchers/$fetcher"
    else
        fetcher="$bootstrap/fetchers/https.sh"
    fi
    if [ ! -e "$fetcher" ]; then
        fail "No fetcher found!"
    fi
    echo "Downloading $REPO/$2"
    "$fetcher" "$@" || return $?
}

infoval() {
    (
        . "$1"
        local val="$2"
        eval "echo \$$val"
    ) || return $?
}

# fetch and verify package info
fetchinfo() {
    fetch "$REPO" "pkgs/$1.pkginfo" "$tmpdir/$1.pkginfo" || return $?
    fetch "$REPO" "pkgs/$1.pkginfo.minisig" "$tmpdir/$1.pkginfo.minisig" || return $?
    minisign -Vm "$tmpdir/$1.pkginfo" -p "$LPKGDIR/pubkey.pub" || return 4
    local iv="$(infoval "$tmpdir/$1.pkginfo" NAME)" || return $?
    if [ "$iv" != "$1" ]; then
        echo "Package name mismatch: requested $1 but got $iv" >&2
        return 4
    fi
}

contains() {
    local i a="$1"
    shift
    for i in $@; do
        if [ "$i" == "$a" ]; then
            return 0
        fi
    done
    return 1
}

resdep() {
    if contains $1 $deps; then
        return 0
    fi
    fetchinfo $1 || return $?
    deps="$deps $1"
    for i in $(infoval "$tmpdir/$1.pkginfo" DEPENDENCIES); do
        resdep "$i" || return $?
    done
    depo="$depo $1"
}

resdeptree() {
    deps=
    depo=
    for i in $@; do
        resdep $i || return $?
    done
}

fetchpkg() {
    local hash=$(infoval "$tmpdir/$1.pkginfo" SHA256SUM) || return 4
    if [ -z "$hash" ]; then
        echo "No hash in pkginfo!" >&2
        return 4
    fi
    fetch "$REPO" "pkgs/$1.tar.gz" "$tmpdir/$1.tar.gz" || return $?
    if [ "$hash" != "$(sha256sum "$tmpdir/$1.tar.gz" | awk '{print $1}')" ]; then
        echo "SHA256 hash does not match on $1.tar.gz!" >&2
        return 4
    fi
}

instpkg() {
    if [ -z "$bootstrap" ]; then
        lpkg-inst "$tmpdir/$1.tar.gz" || return $?
    else
        sh "$bootstrap"/inst.sh "$tmpdir/$1.tar.gz" || return $?
    fi
}

rmpkg() {
    if [ -z "$bootstrap" ]; then
        lpkg-rm "$@" || return $?
    else
        sh "$bootstrap"/rm.sh $@ || return $?
    fi
}

calcchange() {
    toinstall=
    toupdate=
    toremove=
    insto=
    for i in $depo; do
        if [ -d "$LPKGDIR/db/$i" ]; then
            local nver=$(infoval "$tmpdir/$i.pkginfo" VERSION)
            if [ -z "$nver" ]; then
                echo "No version??????" >&2
                return 2
            fi
            local over=$(infoval "$LPKGDIR/db/$i/pkginfo.sh" VERSION)
            if [ -z "$over" ]; then
                echo "No version??????" >&2
                return 2
            fi
            if vercmp "$nver" "$over"; then
                toupdate="$toupdate $i"
                insto="$insto $i"
            fi
        else
            toinstall="$toinstall $i"
            insto="$insto $i"
        fi
    done
    for i in $(ls "$LPKGDIR/db"); do
        if ! contains "$i" $deps; then
            toremove="$toremove $i"
        fi
    done
}

ynprompt() {
    echo -n "$1"
    read ok
    if [ "$ok" == y ]; then
        return 0
    elif [ "$ok" == Y ]; then
        return 0
    elif [ "$ok" == n ]; then
        return 1
    elif [ "$ok" == N ]; then
        return 1
    else
        return "$2"
    fi
}

prompt() {
    echo "To install:"
    for i in $toinstall; do
        echo $'\t'"$i"
    done
    echo "To update:"
    for i in $toupdate; do
        echo $'\t'"$i"
    done
    echo "To remove:"
    for i in $toremove; do
        echo $'\t'"$i"
    done
    if [ "$NONINTERACTIVE" != 1 ]; then
        if ynprompt "Ok? (y/N): "; then
            return 0
        else
            echo "Transaction cancelled" >&2
            return 1
        fi
    fi
}

transact() {
    resdeptree "$@" || return 2
    calcchange
    prompt || return $?
    echo "Downloading packages"
    for i in $insto; do
        fetchpkg $i || return 2
    done
    echo "Installing packages"
    for i in $insto; do
        instpkg $i || return 3
    done
    for i in $toremove; do
        rmpkg $i || return 3
    done
}

setup() {
    if [ -z "$LPKGDIR" ]; then
        echo "LPKGDIR not set. Assuming $ROOTFS/etc/lpkg.d"
        LPKGDIR="$ROOTFS/etc/lpkg.d"
    fi

    if [ ! -d "$LPKGDIR" ]; then
        fail "$LPKGDIR does not exist" 2
    fi
    if [ ! -e "$LPKGDIR/lpkg.conf" ]; then
        fail "lpkg.conf is missing" 3
    fi
    . "$LPKGDIR/lpkg.conf"
    export LPKGDIR
    tmpdir=$(mktemp -d) || return 2
}

tmpcleanup() {
    rm -rf "$tmpdir"
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 [subcommand]"
    echo "Run $0 help for more help"
    exit 1
fi

if [ "$1" == "help" ]; then
    echo "Subcommands: install, bootstrap, update, remove"
elif [ "$1" == "install" ]; then
    if [ $# -lt 2 ]; then
        echo "Nothing specified to install!" >&2
        exit 1
    fi
    shift
    setup || fail "Failed to create temporary directory" 2
    pins=$(cat "$LPKGDIR/pins.list") || fail "Failed to read pin list" 2
    transact $pins $@ || fail "Transaction failed" 3
    for i in $@; do
        if ! contains $i $pins; then
            echo $i >> "$LPKGDIR/pins.list"
        fi
    done
    tmpcleanup
elif [ "$1" == "update" ]; then
    setup || fail "Failed to create temporary directory" 2
    pins=$(cat "$LPKGDIR/pins.list") || fail "Failed to read pin list" 2
    transact $pins || fail "Transaction failed" 3
    tmpcleanup
elif [ "$1" == "remove" ]; then
    shift
    setup || fail "Failed to create temporary directory" 2
    opins=$(cat "$LPKGDIR/pins.list") || fail "Failed to read pin list" 2
    for i in $@; do
        if ! contains $i $opins; then
            tmpcleanup
            fail "$i is not pinned" 1
        fi
    done
    pins=
    for i in $opins; do
        if ! contains $i $@; then
            pins="$pins $i"
        fi
    done
    transact $pins || fail "Transaction failed" 3
    tmpcleanup
    (
        for i in $pins; do
            echo $i
        done
    ) > "$LPKGDIR/pins.list"
elif [ "$1" == "bootstrap" ]; then
    if [ $# -lt 5 ]; then
        echo "Missing arguments" >&2
        exit 1
    fi
    export bootstrap="$PWD"
    export ROOTFS="$2"
    REPO="$3/$4/$5"
    mkdir "$ROOTFS" || fail "Failed to mkdir $ROOTFS" 2
    mkdir -p "$ROOTFS/etc/lpkg.d/db" || fail "Failed to create lpkg.d" 2
    curl "https://$3/minisign.pub" > "$ROOTFS/etc/lpkg.d/pubkey.pub" || fail "Failed to download public key" 4
    shift
    shift
    shift
    shift
    shift
    if [ $# -lt 1 ]; then
        pkgs=base
    else
        pkgs="$@"
    fi
    echo "REPO=\"$REPO\"" > "$ROOTFS/etc/lpkg.d/lpkg.conf"
    setup || fail "Failed to create temporary directory" 2
    transact $pkgs || fail "Failed transaction" 3
    for i in $pkgs; do
        echo $i >> "$LPKGDIR/pins.list"
    done
    echo "Bootstrap complete!"
    tmpcleanup
else
    fail "Invalid subcommand" 1
fi
