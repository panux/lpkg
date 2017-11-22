#!/bin/sh

if [ $# -ne 3 ]; then
    echo "Usage: $0 REPO PATH DEST"
    echo "Wrong number of arguments" >&2
    exit 1
fi

wget -q "http://$1/$2" -O "$3" || exit 2
