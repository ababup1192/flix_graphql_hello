#!/usr/bin/env bash
# src/ の中で CmsErr.runWithResult を呼ぶファイルを集め、scripts/cmserr-allowlist.txt（Tx の境界）と突き合わせる。増えても減っても落ちる。
# WhyNot: ユースケースの途中で呼ぶと業務エラーが Tx の中で値に潰れ、ROLLBACK も errors[] への写しも起きないため、Tx の境界以外では呼ばせない。
# test/ は対象にしない。テストは自分で境界を作るのが仕事なので。
set -eu
cd "$(dirname "$0")/.."

found=$(grep -rl --include='*.flix' 'CmsErr\.runWithResult' src | sort)
allowed=$(grep -v '^#' scripts/cmserr-allowlist.txt | grep -v '^[[:space:]]*$' | sort)

if [ "$found" != "$allowed" ]; then
    echo "CmsErr.runWithResult を呼ぶファイルが scripts/cmserr-allowlist.txt と合いません（< 実際 / > 一覧）:" >&2
    diff <(printf '%s\n' "$found") <(printf '%s\n' "$allowed") >&2 || true
    exit 1
fi
