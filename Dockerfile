FROM alpine:3.22

ARG WITH_EMBED=false
ARG APP_USER=lrc
ARG APP_UID=1000
ARG APP_GID=1000
ARG APP_BIN=/usr/local/bin/lrcget_bash.sh

ARG BASH_VER=5.2
ARG CURL_VER=8.14
ARG JQ_VER=1.8
ARG FFMPEG_VER=6.1
ARG FINDUTILS_VER=4.10
ARG KID3_VER=3.9

RUN apk add --no-cache \
    bash~=${BASH_VER} \
    curl~=${CURL_VER} \
    jq~=${JQ_VER} \
    ffmpeg~=${FFMPEG_VER} \
    findutils~=${FINDUTILS_VER} \
    ca-certificates

RUN if [ "$WITH_EMBED" = "true" ]; then \
      apk add --no-cache kid3~=${KID3_VER} ; \
    fi

RUN addgroup -g ${APP_GID} -S ${APP_USER} \
    && adduser -u ${APP_UID} -S -G ${APP_USER} -h /home/${APP_USER} ${APP_USER}

WORKDIR /data

COPY --chown=${APP_UID}:${APP_GID} lrcget_bash.sh ${APP_BIN}

RUN chmod 0755 ${APP_BIN}

USER ${APP_UID}:${APP_GID}

ENTRYPOINT ["/usr/local/bin/lrcget_bash.sh"]
