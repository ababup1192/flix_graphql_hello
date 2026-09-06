///
/// graphql のテストで共有する enum。GqlCodec の enum・SDL の enum 出力・値の変換で同じ物を使う。
///
pub enum Color {
    case Red
    case Blue
}

mod Color {

    ///
    /// Color の GqlCodec（RED / BLUE）。
    ///
    pub def codec(): GqlCodec[Color] =
        GqlCodec.enumOf("Color", color -> match color { case Color.Red => "RED" case Color.Blue => "BLUE" }, Color.Red :: Color.Blue :: Nil)

}
