FROM prefecthq/prefect:3-latest

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "prefect-docker>=0.3.0"
