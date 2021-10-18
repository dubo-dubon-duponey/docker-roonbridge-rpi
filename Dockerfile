ARG           FROM_REGISTRY=ghcr.io/dubo-dubon-duponey

ARG           FROM_IMAGE_FETCHER=base:golang-bullseye-2021-10-15@sha256:0baa9b0041a5b684ecec2fee65359b00773e41d087ce5413b1ce5801e97bfac4
ARG           FROM_IMAGE_BUILDER=base:builder-bullseye-2021-10-15@sha256:33e021267790132e63be2cea08e77d64ec5d0434355734e94f8ff2d90c6f8944
ARG           FROM_IMAGE_AUDITOR=base:auditor-bullseye-2021-10-15@sha256:eb822683575d68ccbdf62b092e1715c676b9650a695d8c0235db4ed5de3e8534
ARG           FROM_IMAGE_TOOLS=tools:linux-bullseye-2021-10-15@sha256:e8ec2d1d185177605736ba594027f27334e68d7984bbfe708a0b37f4b6f2dbd7
ARG           FROM_IMAGE_RUNTIME=base:runtime-bullseye-2021-10-15@sha256:7072702dab130c1bbff5e5c4a0adac9c9f2ef59614f24e7ee43d8730fae2764c

FROM          $FROM_REGISTRY/$FROM_IMAGE_TOOLS                                                                          AS builder-tools

FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_BUILDER                                              AS fetcher-caddy

ARG           GIT_REPO=github.com/caddyserver/caddy
# 2.4.5 need tweak to scep (minor version bump), but then the build segfaults
ARG           GIT_VERSION=v2.4.3
ARG           GIT_COMMIT=9d4ed3a3236df06e54c80c4f6633b66d68ad3673

ENV           WITH_BUILD_SOURCE="./cmd/caddy"
ENV           WITH_BUILD_OUTPUT="caddy"

ENV           CGO_ENABLED=1
ENV           ENABLE_STATIC=true

RUN           git clone --recurse-submodules git://"$GIT_REPO" .; git checkout "$GIT_COMMIT"

# scep v2.0.0 checksum does not match anymore
# It's unclear whether the rename of the module to v2 is responsible, but one way or the other this
# *critical* module is suspicious
# RUN           echo "replace github.com/micromdm/scep/v2 v2.0.0 => github.com/micromdm/scep/v2 v2.1.0" >> go.mod

ARG           GIT_REPO_REPLACE=github.com/caddyserver/replace-response
ARG           GIT_VERSION_REPLACE=9d5652c
ARG           GIT_COMMIT_REPLACE=9d5652c0256308fddaef1453d463d2a281498cb6

RUN           echo "require $GIT_REPO_REPLACE $GIT_COMMIT_REPLACE" >> go.mod

# hadolint ignore=DL3045
COPY          build/main.go ./cmd/caddy/main.go

RUN           --mount=type=secret,id=CA \
              --mount=type=secret,id=NETRC \
              go mod tidy; \
              [[ "${GOFLAGS:-}" == *-mod=vendor* ]] || go mod download

#######################
# Main builder
#######################
FROM          --platform=$BUILDPLATFORM fetcher-caddy                                                                    AS builder-caddy

ARG           TARGETARCH
ARG           TARGETOS
ARG           TARGETVARIANT
ENV           GOOS=$TARGETOS
ENV           GOARCH=$TARGETARCH

ENV           CGO_CFLAGS="${CFLAGS:-} ${ENABLE_PIE:+-fPIE}"
ENV           GOFLAGS="-trimpath ${ENABLE_PIE:+-buildmode=pie} ${GOFLAGS:-}"

RUN           export GOARM="$(printf "%s" "$TARGETVARIANT" | tr -d v)"; \
              [ "${CGO_ENABLED:-}" != 1 ] || { \
                eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
                export PKG_CONFIG="${DEB_TARGET_GNU_TYPE}-pkg-config"; \
                export AR="${DEB_TARGET_GNU_TYPE}-ar"; \
                export CC="${DEB_TARGET_GNU_TYPE}-gcc"; \
                export CXX="${DEB_TARGET_GNU_TYPE}-g++"; \
                [ ! "${ENABLE_STATIC:-}" ] || { \
                  [ ! "${WITH_CGO_NET:-}" ] || { \
                    ENABLE_STATIC=; \
                    LDFLAGS="${LDFLAGS:-} -static-libgcc -static-libstdc++"; \
                  }; \
                  [ "$GOARCH" == "amd64" ] || [ "$GOARCH" == "arm64" ] || [ "${ENABLE_PIE:-}" != true ] || ENABLE_STATIC=; \
                }; \
                WITH_LDFLAGS="${WITH_LDFLAGS:-} -linkmode=external -extld="$CC" -extldflags \"${LDFLAGS:-} ${ENABLE_STATIC:+-static}${ENABLE_PIE:+-pie}\""; \
                WITH_TAGS="${WITH_TAGS:-} cgo ${ENABLE_STATIC:+static static_build}"; \
              }; \
              go build -ldflags "-s -w -v ${WITH_LDFLAGS:-}" -tags "${WITH_TAGS:-} net${WITH_CGO_NET:+c}go osusergo" -o /dist/boot/bin/"$WITH_BUILD_OUTPUT" "$WITH_BUILD_SOURCE"

##########################
# Bridge: builder
##########################
FROM          $FROM_REGISTRY/$FROM_IMAGE_AUDITOR                                                                        AS builder-bridge

ARG           TARGETPLATFORM
ARG           TARGETARCH
ARG           TARGETVARIANT

# Install dependencies and tools: bridge
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              apt-get update -qq && \
              apt-get install -qq --no-install-recommends \
                bzip2=1.0.8-4 \
                libasound2=1.2.4-1.1

WORKDIR       /dist/boot/bin
COPY          "./cache/$TARGETPLATFORM/bridge.tar.bz2" .
RUN           tar -xjf bridge.tar.bz2
RUN           rm bridge.tar.bz2
RUN           ./RoonBridge/check.sh

# XXX do we NEED libasound?
RUN           mkdir -p /dist/boot/lib; \
              eval "$(dpkg-architecture -A "$(echo "$TARGETARCH$TARGETVARIANT" | sed -e "s/^armv6$/armel/" -e "s/^armv7$/armhf/" -e "s/^ppc64le$/ppc64el/" -e "s/^386$/i386/")")"; \
              cp /usr/lib/"$DEB_TARGET_MULTIARCH"/libasound.so.2  /dist/boot/lib

#######################
# Bridge: assembly
#######################
FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_AUDITOR                                              AS assembly-bridge

COPY          --from=builder-bridge /dist/boot      /dist/boot
COPY          --from=builder-bridge /usr/share/alsa /dist/usr/share/alsa

RUN           chmod 555 /dist/boot/bin/*; \
              epoch="$(date --date "$BUILD_CREATED" +%s)"; \
              find /dist/boot -newermt "@$epoch" -exec touch --no-dereference --date="@$epoch" '{}' +;

#######################
# Bridge: runtime
#######################
FROM          $FROM_REGISTRY/$FROM_IMAGE_RUNTIME                                                                        AS runtime-bridge

COPY          --from=assembly-bridge --chown=$BUILD_UID:root  /dist /

# XXX LD_LIBRARY_PATH are a liability when mixed with caps - so, watch out
# Alternative is rpathing, but what exactly?
ENV           LD_LIBRARY_PATH=/boot/lib

ENV           ROON_DATAROOT=/data/data_root
ENV           ROON_ID_DIR=/data/id_dir

VOLUME        /data
VOLUME        /tmp

##########################
# Building image server
##########################
FROM          $FROM_REGISTRY/$FROM_IMAGE_AUDITOR                                                                        AS builder-server

# Install dependencies and tools: bridge
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              apt-get update -qq && \
              apt-get install -qq --no-install-recommends \
                bzip2=1.0.8-4 \
                libasound2=1.2.4-1.1 \
                ffmpeg=7:4.3.2-0+deb11u2 \
                cifs-utils=2:6.11-3.1

WORKDIR       /dist/boot/bin
COPY          "./cache/linux/amd64/server.tar.bz2" .
RUN           tar -xjf server.tar.bz2
RUN           rm server.tar.bz2
RUN           ./RoonServer/check.sh

RUN           ln -s mono-sgen /dist/boot/bin/RoonServer/RoonMono/bin/RAATServer
RUN           ln -s mono-sgen /dist/boot/bin/RoonServer/RoonMono/bin/RoonAppliance
RUN           ln -s mono-sgen /dist/boot/bin/RoonServer/RoonMono/bin/RoonServer

#######################
# Builder assembly for server
#######################
FROM          --platform=$BUILDPLATFORM $FROM_REGISTRY/$FROM_IMAGE_AUDITOR                                              AS assembly

ARG           TARGETARCH

COPY          --from=builder-server /dist/boot              /dist/boot

COPY          --from=builder-caddy  /dist/boot/bin/caddy    /dist/boot/bin
#COPY          --from=builder-tools  /boot/bin/caddy          /dist/boot/bin
COPY          --from=builder-tools  /boot/bin/goello-server-ng /dist/boot/bin
COPY          --from=builder-tools  /boot/bin/http-health   /dist/boot/bin

RUN           setcap 'cap_net_bind_service+ep'              /dist/boot/bin/caddy

RUN           RUNNING=true \
              STATIC=true \
                dubo-check validate /dist/boot/bin/http-health

RUN           RUNNING=true \
              STATIC=true \
                dubo-check validate /dist/boot/bin/goello-server

RUN           RUNNING=true \
              RO_RELOCATIONS=true \
              STATIC=true \
                dubo-check validate /dist/boot/bin/caddy

RUN           chmod 555 /dist/boot/bin/*; \
              epoch="$(date --date "$BUILD_CREATED" +%s)"; \
              find /dist/boot -newermt "@$epoch" -exec touch --no-dereference --date="@$epoch" '{}' +;

#######################
# Running image server
#######################
FROM          $FROM_REGISTRY/$FROM_IMAGE_RUNTIME                                                                        AS runtime-server

USER          root

# Removing this will prevent the RoonServer from using audio devices, hence making the use of RaatBridges mandatory (which is fine)
#                libasound2=1.2.4-1.1 \
RUN           --mount=type=secret,uid=100,id=CA \
              --mount=type=secret,uid=100,id=CERTIFICATE \
              --mount=type=secret,uid=100,id=KEY \
              --mount=type=secret,uid=100,id=GPG.gpg \
              --mount=type=secret,id=NETRC \
              --mount=type=secret,id=APT_SOURCES \
              --mount=type=secret,id=APT_CONFIG \
              apt-get update -qq \
              && apt-get install -qq --no-install-recommends \
                ffmpeg=7:4.3.2-0+deb11u2 \
              && apt-get -qq autoremove       \
              && apt-get -qq clean            \
              && rm -rf /var/lib/apt/lists/*  \
              && rm -rf /tmp/*                \
              && rm -rf /var/tmp/*

USER          dubo-dubon-duponey

ENV           ROON_DATAROOT=/data/data_root
ENV           ROON_ID_DIR=/data/id_dir
EXPOSE        9003/udp
VOLUME        /music

ENV           NICK="roon"

COPY          --from=assembly --chown=$BUILD_UID:root /dist /

### Front server configuration
# Port to use
ENV           PORT_HTTPS=443
ENV           PORT_HTTP=80
EXPOSE        443
EXPOSE        80
# Log verbosity for
ENV           LOG_LEVEL="warn"
# Domain name to serve
ENV           DOMAIN="$NICK.local"
ENV           ADDITIONAL_DOMAINS="https://*.debian.org"
# Whether the server should behave as a proxy (disallows mTLS)
ENV           SERVER_NAME="DuboDubonDuponey/1.0 (Caddy/2) [$NICK]"
# Control wether tls is going to be "internal" (eg: self-signed), or alternatively an email address to enable letsencrypt - use "" to disable TLS entirely
ENV           TLS="internal"
# 1.2 or 1.3
ENV           TLS_MIN=1.3
# Issuer name to appear in certificates
#ENV           TLS_ISSUER="Dubo Dubon Duponey"
# Either disable_redirects or ignore_loaded_certs if one wants the redirects
ENV           TLS_AUTO=disable_redirects
# Either require_and_verify or verify_if_given, or "" to disable mTLS altogether
ENV           MTLS="require_and_verify"
# Root certificate to trust for mTLS
ENV           MTLS_TRUST="/certs/mtls_ca.crt"
# Realm for authentication - set to "" to disable authentication entirely
ENV           AUTH="My Precious Realm"
# Provide username and password here (call the container with the "hash" command to generate a properly encrypted password, otherwise, a random one will be generated)
ENV           AUTH_USERNAME="dubo-dubon-duponey"
ENV           AUTH_PASSWORD="cmVwbGFjZV9tZV93aXRoX3NvbWV0aGluZwo="
### mDNS broadcasting
# Type to advertise
ENV           MDNS_TYPE="_http._tcp"
# Name is used as a short description for the service
ENV           MDNS_NAME="$NICK mDNS display name"
# The service will be annonced and reachable at $MDNS_HOST.local (set to empty string to disable mDNS announces entirely)
ENV           MDNS_HOST="$NICK"
# Also announce the service as a workstation (for example for the benefit of coreDNS mDNS)
ENV           MDNS_STATION=true
# Caddy certs will be stored here
VOLUME        /certs
# Caddy uses this
VOLUME        /tmp
# Used by the backend service
VOLUME        /data
ENV           HEALTHCHECK_URL="http://127.0.0.1:10000/?healthcheck"

HEALTHCHECK   --interval=120s --timeout=30s --start-period=10s --retries=1 CMD http-health || exit 1
