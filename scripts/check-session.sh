#!/usr/bin/env bash
# src/cms のユースケースの pub def のうち、DB に触る（effect に Db / DbRead / DbWrite がある）のに Session も権限の証明（引数の `Granted[…]`）も
# 持たない物を集め、scripts/session-allowlist.txt（写し・outbox・Runner が主体を決める前に呼ぶ物）と突き合わせる。増えても減っても落ちる。
# WhyNot: Flix のテストにしないのは、Flix に reflection が無く、名前の一覧を書いても検査にならないため。
set -eu
cd "$(dirname "$0")/.."

found=$(awk '
    /^mod [A-Za-z]+/ { mod = $2 }
    /^[[:space:]]*pub def / && /\\/ && /(^|[^A-Za-z])Db(Read|Write)?([^A-Za-z]|$)/ && !/(^|[^A-Za-z])Session([^A-Za-z]|$)/ && !/: Granted\[/ {
        name = $0
        sub(/^[[:space:]]*pub def /, "", name)
        sub(/[(\[:].*/, "", name)
        print mod "." name
    }
' src/cms/*.flix | sort)
allowed=$(grep -v '^#' scripts/session-allowlist.txt | grep -v '^[[:space:]]*$' | sort)

if [ "$found" != "$allowed" ]; then
    echo "Session を持たない pub のユースケースが scripts/session-allowlist.txt と合いません（< 実際 / > 一覧）:" >&2
    diff <(printf '%s\n' "$found") <(printf '%s\n' "$allowed") >&2 || true
    exit 1
fi
