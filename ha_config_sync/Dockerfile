FROM ghcr.io/home-assistant/base:latest

RUN apk add --no-cache \
    git \
    openssh-client \
    curl \
    jq

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
