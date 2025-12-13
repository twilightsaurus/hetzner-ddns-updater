FROM alpine:3.19

RUN apk add --no-cache curl bind-tools jq

# Persist last applied IP across restarts
VOLUME ["/state"]

# Copy entrypoint script
COPY update.sh /update.sh
RUN chmod +x /update.sh

ENV CRON_INTERVAL="*/5 * * * *"

ENTRYPOINT ["/update.sh"]

