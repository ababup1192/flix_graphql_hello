///
/// ULID（時刻順に並ぶ 26 文字の id）。先頭 10 文字がミリ秒の時刻、後ろ 16 文字が乱数。Crockford の base32。
/// 配信記録のように「追記だけで時刻順に読む物」の id に使う。作成時刻が id から読めるので、鍵や組織の外向き id には使わない。
///
mod Ulid {

    /// Crockford の base32（I L O U を除く）。
    def alphabet(): String = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    ///
    /// ミリ秒の時刻と 10 バイトの乱数から組む。乱数が 10 バイトに足りなければ 0 で埋め、余れば捨てる。
    ///
    pub def encode(timeMs: Int64, random: Vector[Int8]): String =
        let padded = Vector.append(random, Vector.repeat(10, 0i8)) |> Vector.take(10);
        let high = padded |> Vector.take(5) |> toInt64;
        let low = padded |> Vector.drop(5) |> toInt64;
        chars(10, timeMs) + chars(8, high) + chars(8, low)

    ///
    /// その時刻に作られ得る ULID の最小値（乱数の部分が全部 0）。時刻の範囲を id の範囲に変えるのに使う
    /// （`id >= lowerBoundAt(since) AND id < lowerBoundAt(until)`）。
    ///
    pub def lowerBoundAt(timeMs: Int64): String =
        encode(timeMs, Vector.empty())

    /// 5 バイトを 40 bit の整数に。
    def toInt64(bytes: Vector[Int8]): Int64 =
        Vector.foldLeft((acc, byte) -> (acc * 256i64) + Int32.toInt64(Int8.toInt32(byte) |> Int32.bitwiseAnd(255)), 0i64, bytes)

    /// 値の下位 5 × count bit を、上位から count 文字に。
    def chars(count: Int32, value: Int64): String =
        List.range(0, count)
            |> List.map(index -> {
                let shift = 5 * (count - 1 - index);
                let digit = Int64.bitwiseAnd(Int64.logicalRightShift(dist = shift, value), 31i64) |> Int64.clampToInt32(min = 0, max = 31);
                String.charAt(digit, alphabet()) |> Char.toString
            })
            |> List.join("")

}
