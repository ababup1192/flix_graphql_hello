#!/usr/bin/env bash
# src/ の中で withLazyTx（Pool / TenantTx）か、Tx を手で組む部品（Pool.borrow / Tx.begin / Jdbc.executeStatement / Jdbc.runWithConnection）を呼ぶファイルを集め、
# scripts/tx-allowlist.txt（Tx を張る入口）と突き合わせる。増えても減っても落ちる。
# WhyNot: 呼び出し側で直に Tx を張らせないのは、再試行・Db.guard の位置・RLS の印の 3 つが入口ごとにばらつくため。入口は DbRunner の transact / withTx / withRequestTx に寄せる。
# test/ は対象にしない。テストは自分で境界を作るのが仕事なので。
set -eu
cd "$(dirname "$0")/.."

found=$(grep -rlE --include='*.flix' 'withLazyTx[A-Za-z]*\(|Pool\.borrow\(|Tx\.begin\(|Jdbc\.executeStatement\(|Jdbc\.runWithConnection\(' src | sort)
allowed=$(grep -v '^#' scripts/tx-allowlist.txt | grep -v '^[[:space:]]*$' | sort)

if [ "$found" != "$allowed" ]; then
    echo "withLazyTx を呼ぶファイルが scripts/tx-allowlist.txt と合いません（< 実際 / > 一覧）:" >&2
    diff <(printf '%s\n' "$found") <(printf '%s\n' "$allowed") >&2 || true
    exit 1
fi
