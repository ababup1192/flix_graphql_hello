# CMS のイメージ。build 段で Flix コンパイラ（GitHub release の jar）を取って fat jar を作り、
# runtime 段は JRE と jar と、起動時に読む admin.graphql / migrations/ だけを持つ。
# amd64 / arm64 の両方でそのまま動く（JVM なので buildx の --platform だけで済む）。
#
# WhyNot: Flix コンパイラをイメージに残さないのは、runtime に要るのが JRE と jar だけで、
# コンパイラ（数百 MB のメモリを使う）を含めると起動時のメモリ見積もりが狂うため。

ARG FLIX_VERSION=0.75.3

# ---- build ----
FROM eclipse-temurin:21-jdk AS build
ARG FLIX_VERSION
# WhyNot: WORKDIR をプロジェクト名にするのは、Flix が jar の名前をディレクトリ名から付けるため
WORKDIR /build/flix_graphql_hello
ADD https://github.com/flix/flix/releases/download/v${FLIX_VERSION}/flix.jar /opt/flix.jar
# 依存の解決を先に済ませる（flix.toml が変わらない限りキャッシュが効く）
COPY flix.toml ./
RUN java -jar /opt/flix.jar check --Xsubeffecting=lambdas || true
COPY . .
# WhyNot: --Xsubeffecting=lambdas を bin/flix と同じく付けるのは、無いと effect 無しのラムダを IO の関数型に渡せないため
RUN java -Xss32m -jar /opt/flix.jar build-fatjar --Xsubeffecting=lambdas

# ---- runtime ----
FROM eclipse-temurin:21-jre
ARG CMS_VERSION=dev
ENV CMS_VERSION=${CMS_VERSION} \
    CMS_MIGRATE=apply \
    JAVA_OPTS="-Xss32m -XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError"
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/flix_graphql_hello/artifact/flix_graphql_hello.jar ./cms.jar
COPY admin.graphql ./
COPY migrations ./migrations
RUN useradd --system --uid 10001 cms && chown -R cms:cms /app
USER cms
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
    CMD ["curl", "-fsS", "http://127.0.0.1:8080/health"]
CMD ["sh", "-c", "exec java $JAVA_OPTS -jar /app/cms.jar"]
