# PocketBase — construit depuis le binaire officiel épinglé.
# (Il n'existe pas d'image Docker officielle PocketBase ; on build depuis la release GitHub.)
# Multi-arch : TARGETARCH est fourni par BuildKit (amd64 | arm64).
ARG PB_VERSION=0.39.5

FROM alpine:3.20 AS build
ARG PB_VERSION
ARG TARGETARCH
RUN apk add --no-cache unzip ca-certificates wget
WORKDIR /pb
RUN wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" -O pb.zip \
    && unzip pb.zip \
    && rm pb.zip

FROM alpine:3.20
RUN apk add --no-cache ca-certificates wget
COPY --from=build /pb/pocketbase /usr/local/bin/pocketbase
WORKDIR /pb
# pb_data (DB + fichiers) = volume persistant, sauvegardé par restic.
# pb_migrations = migrations de schéma versionnées (montées en lecture).
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8090/api/health || exit 1
ENTRYPOINT ["pocketbase"]
CMD ["serve", "--http=0.0.0.0:8090"]
