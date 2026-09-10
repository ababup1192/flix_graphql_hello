#!/usr/bin/env bash
# src/ の中で Session / Tenant / CmsErr の handler を入れるファイルと、Granted の中身を組み立てるファイルを集め、
# scripts/handler-allowlist.txt と突き合わせる。増えても減っても落ちる。
#
# WhyNot: 型と effect はここを守れない。非 pub の enum も pub eff も、外の mod から
# `Granted.Granted(Session.Seal.Seal)` や `run … with handler Tenant { … }` を書けば
# 主体もプロジェクトも業務エラーも自由に差し替えられる（2026-09-11 に実測）。
# 「作れるのは mod の中だけ」は Flix では表現できないので、見張りで代わりにする。
set -eu
cd "$(dirname "$0")/.."

found=$(grep -rlE --include='*.flix' 'with (handler )?(Session|Tenant|CmsErr)[[:space:]]*\{|Granted\.Granted\(' src | sort)
allowed=$(grep -v '^#' scripts/handler-allowlist.txt | grep -v '^[[:space:]]*$' | sort)

if [ "$found" != "$allowed" ]; then
    echo "Session / Tenant / CmsErr の handler か Granted の組み立てが scripts/handler-allowlist.txt と合いません（< 実際 / > 一覧）:" >&2
    diff <(printf '%s\n' "$found") <(printf '%s\n' "$allowed") >&2 || true
    exit 1
fi
