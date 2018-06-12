#!/usr/bin/busybox sh

# Alternative is a script to manage files provided by multiple packages

fail() {
    echo "ERROR: $1" >&2
    if [ -z "$2" ]; then
        exit 1
    fi
    exit "$2"
}

if [ $# -eq 0 ]; then
    echo "Usage: $0 [update|reconfigure]"
    fail "No arguments specified"
fi

if [ -z "$LPKGDIR" ]; then
    echo "LPKGDIR not set. Assuming $ROOTFS/etc/lpkg.d"
    LPKGDIR="$ROOTFS/etc/lpkg.d"
fi

if [ ! -d "$LPKGDIR" ]; then
    fail "$LPKGDIR does not exist" 2
fi

# Thing to run when there are changes to providers
update() {
    if [ $# -ne 1 ]; then
        echo "Usage: $0 update [targetname]"
        fail "Wrong number of arguments"
    fi
    ALTD="$LPKGDIR/alt.d/$1"
    if [ ! -d "$ALTD" ]; then
        fail "No alternative dir found: $ALTD" 2
    fi
    provider=$(basename $(ls "$ALTD"/*.provider | sort -rn | head -n1) .provider)
    if [ -z $provider ]; then
        fail "No providers for $1 found!" 2
    fi
    if [ -e "$ALTD/.override" ]; then
        provider=$(cat "$ALTD/.override")
    fi
    if [ ! -L "$ALTD/$provider.provider" ]; then
        fail "Provider $provider does not exist" 2
    fi
    target=$(cat "$ALTD/.target")
    if [ -z "$target" ]; then
        fail "Nothing to provide!" 2
    fi
    ln -sfn "/etc/lpkg.d/alt.d/$1/$provider.provider" "$ROOTFS/$target" || fail "Failed to update link $target" 2
}

# User command to manually override a provider
reconfigure() {
    if [ $# -lt 1 -o $# -gt 2 ]; then
        echo "Usage: $0 reconfigure [targetname] <provider>"
        fail "Wrong number of arguments"
    fi
    ALTD="$LPKGDIR/alt.d/$1"
    if [ ! -d "$ALTD" ]; then
        fail "No alternative dir found: $ALTD" 2
    fi
    if [ $# -eq 2 ]; then
        provider="$2"
    else
        echo Available providers:
        for p in $(ls "$ALTD"/*.provider | sort -rn); do
            echo $'\t'$(basename "$p" .provider)
        done
        read -p "Select provider: " provider
    fi
    if [ ! -e "$ALTD/$provider.provider" ]; then
        fail "Provider $provider does not exist" 2
    fi
    echo "$provider" > "$ALTD/.override"
    update "$1"
}

if [ "$1" == "update" ]; then
    shift
    update "$@"
elif [ "$1" == "reconfigure" ]; then
    shift
    reconfigure "$@"
else
    fail "Unrecognized subcommand $1"
fi
