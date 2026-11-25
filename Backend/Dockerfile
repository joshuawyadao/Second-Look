# syntax=docker/dockerfile:1
# Build from the repository root: docker build -f Backend/Dockerfile .
# Official Swift 6.2.3 image, matching the supported CI server toolchain.
FROM swift:6.2.3-noble@sha256:6dd90eb2359663a2cde8f03e9951f488b23134b3b8fce20e9dcb6cada75dd803 AS build
RUN apt-get update && apt-get install -y --no-install-recommends libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Package.swift ./
COPY SecondLookCore/ SecondLookCore/
COPY SecondLookCoreTests/ SecondLookCoreTests/
COPY SecondLookTransportTests/ SecondLookTransportTests/
COPY SecondLook/Services/Transport/ SecondLook/Services/Transport/
COPY Backend/Package.swift Backend/Package.resolved Backend/
RUN --mount=type=cache,id=secondlook-swiftpm-6.2.3,target=/root/.cache/org.swift.swiftpm,sharing=locked \
    swift package --package-path Backend --cache-path /root/.cache/org.swift.swiftpm resolve --force-resolved-versions
COPY Backend/Sources/ Backend/Sources/
COPY Backend/Tests/ Backend/Tests/
RUN --mount=type=cache,id=secondlook-swiftpm-6.2.3,target=/root/.cache/org.swift.swiftpm,sharing=locked \
    swift build --package-path Backend --cache-path /root/.cache/org.swift.swiftpm -c release --product SecondLookServer \
      --static-swift-stdlib -Xlinker -ljemalloc -j 4 \
    && mkdir /staging \
    && cp "$(swift build --package-path Backend -c release --show-bin-path)/SecondLookServer" /staging/ \
    && find -L "$(swift build --package-path Backend -c release --show-bin-path)" \
      -name '*.resources' -type d -exec cp -Ra {} /staging/ \;

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libcurl4t64 libjemalloc2 tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --user-group --system --create-home --home-dir /app secondlook
WORKDIR /app
COPY --from=build --chown=secondlook:secondlook /staging/ /app/
USER secondlook:secondlook
ENV SECONDLOOK_PORT=8080
EXPOSE 8080
ENTRYPOINT ["./SecondLookServer"]
CMD ["serve", "--env", "production"]
