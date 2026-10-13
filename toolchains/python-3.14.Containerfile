# Python 3.14, copied from the official image (pinned by digest), plus the shared
# libraries it links against. Project packages are installed later with
# `pitainer deps`, never baked in here.
COPY --from=python:3.14-slim-bookworm@sha256:48b13b003dda20b16f9442b8475aa05fe21bf6579a8c881db92ffb4d8fd20f83 /usr/local/ /usr/local/
RUN apt-get update \
  && apt-get install -y --no-install-recommends libffi8 libsqlite3-0 libbz2-1.0 liblzma5 libssl3 zlib1g libncursesw6 libreadline8 libexpat1 libuuid1 \
  && rm -rf /var/lib/apt/lists/* \
  && ldconfig \
  && python3 --version && python3 -c "import ssl, sqlite3, ctypes, venv" && pip --version
