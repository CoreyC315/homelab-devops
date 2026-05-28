FROM python:3.12-slim

WORKDIR /app

COPY manga_watch ./manga_watch

ENV CONFIG_PATH=/config/config.json \
    STATE_PATH=/state/manga-watch.sqlite \
    DATA_PATH=/data/manga \
    PYTHONUNBUFFERED=1

USER 1000:1000

ENTRYPOINT ["python", "-m", "manga_watch"]
CMD ["serve"]
