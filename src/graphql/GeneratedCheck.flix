///
/// 生成物（src/generated/GeneratedSchema.flix）が今の schema.graphql から、期待する版の生成器で作られた物かの照合。
///
mod GeneratedCheck {

    ///
    /// 本体が期待する生成器（schemagen の Emit.generatorVersion）のバージョン。生成器の出力の形を変えたら一緒に上げる。
    ///
    /// WhyNot: 生成物に埋まった Generated.generatorVersion だけを見ないのは、それだと古い生成物が
    /// 自分の版で自分を検証してしまい、生成器を直しても再生成が要求されないため。
    ///
    pub def expectedGeneratorVersion(): String = "6"

    ///
    /// 生成物に埋まった SDL 本文と生成器バージョンを、schema.graphql の本文と期待する版に照らす。
    ///
    /// WhyNot: ハッシュにしないのは、本体と生成器で同じ計算を 2 か所に持つ事になるため。本文をそのまま
    /// 埋めれば比較は文字列の一致だけで済む。
    ///
    pub def check(sdl: String): Result[String, Unit] =
        let normalized = String.replace(src = "\r\n", dst = "\n", sdl);
        if (Generated.generatorVersion() != expectedGeneratorVersion())
            Err("src/generated/GeneratedSchema.flix は生成器の版 ${Generated.generatorVersion()} で作られています（期待は ${expectedGeneratorVersion()}）。`make generate` で作り直してください")
        else if (Generated.sdlText() != normalized)
            Err("schema.graphql と src/generated/GeneratedSchema.flix が食い違っています。`make generate` で作り直してください")
        else Ok(())

}
