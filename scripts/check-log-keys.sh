#!/usr/bin/env bash
# src の Log.Fields.str / int / bool / strs / opt のキーの literal を集め、docs/logging.md のキーの一覧（表の 1 列目の `key`）と突き合わせる。
# 一覧に無いキーが 1 つでもあれば落ちる（email や URL や生の鍵のキーが増えた時にレビューで見える）。
# WhyNot: Flix のテストにしないのは、Flix に reflection が無く、キーの一覧を書いても検査にならないため。
set -eu
cd "$(dirname "$0")/.."

# コメントの例（`Fields.str("k", "v")`）は数えない
found=$(grep -rhE 'Fields\.(str|int|bool|strs|opt)\("' --exclude-dir=generated src | grep -vE '^[[:space:]]*//' \
    | grep -oE 'Fields\.(str|int|bool|strs|opt)\("[^"]+"' | sed -E 's/.*\("//; s/"$//' | sort -u)
listed=$(grep -oE '^\| `[^`]+`' docs/logging.md | sed -E 's/^\| `//; s/`$//' | sort -u)

missing=$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' "$listed"))
if [ -n "$missing" ]; then
    echo "docs/logging.md の一覧に無いログのキーがあります（足すなら一覧に書く。秘密や個人情報のキーは足さない）:" >&2
    printf '  %s\n' $missing >&2
    exit 1
fi
