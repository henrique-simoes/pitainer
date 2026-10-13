# pitainer base image: stock pi plus the security core. Nothing else belongs here;
# toolchains are separate layers under toolchains/.
#
# Pinned inputs. Change them only through `pitainer update` and review the diff.
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20
FROM ${NODE_IMAGE}

ARG PI_VERSION=1.2.0
ARG PI_INTEGRITY=sha512-h/4WaVWv1VlCaY8x8qEN5U+7jbF/e7+Ck6moPeEOFn5juMTWwNAXjwgYM7gRgbBYh8Zppwt6qWvJDzNTf4GNEQ==

# bash, git, ripgrep, ca-certificates: required by pi (see pi's containerization doc).
# iptables: per-user firewall.  sudo: pi -> tools user switch for the offline shell.
# e2fsprogs: chattr, to make pi's settings immutable.
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates git ripgrep iptables sudo e2fsprogs \
  && rm -rf /var/lib/apt/lists/*

# Verify the published checksum before installing; never run install scripts.
RUN set -eu; cd /tmp; \
  npm pack --silent "@earendil-works/pi-coding-agent@${PI_VERSION}" >/dev/null; \
  got="sha512-$(openssl dgst -sha512 -binary earendil-works-pi-coding-agent-${PI_VERSION}.tgz | openssl base64 -A)"; \
  [ "$got" = "${PI_INTEGRITY}" ] || { echo "pi checksum mismatch: $got" >&2; exit 1; }; \
  npm install -g --ignore-scripts "/tmp/earendil-works-pi-coding-agent-${PI_VERSION}.tgz"; \
  rm -f /tmp/*.tgz; npm cache clean --force >/dev/null 2>&1

# Four users, one shared group so files in mounted folders stay usable by all of them.
#   pi    runs pi            tools runs every command pi launches (no network)
#   deps  user-run installs  pxy   the allow-list proxy (the only user let out)
RUN groupadd -g 1200 work \
  && useradd -u 1100 -g work -m -s /bin/bash pi \
  && useradd -u 1101 -g work -m -s /bin/bash tools \
  && useradd -u 1102 -g work -m -s /bin/bash deps \
  && useradd -u 1103 -U -M -s /usr/sbin/nologin pxy \
  && mkdir -p /work /deps /home/pi/.pi/agent

COPY image/ /usr/local/libexec/pitainer/
RUN chown -R root:root /usr/local/libexec/pitainer \
  && chmod 0755 /usr/local/libexec/pitainer/* \
  && chmod 0644 /usr/local/libexec/pitainer/settings.json \
  && install -m 0440 -o root -g root /usr/local/libexec/pitainer/sudoers /etc/sudoers.d/pitainer \
  && rm /usr/local/libexec/pitainer/sudoers \
  && visudo -cf /etc/sudoers.d/pitainer \
  && mkdir -p /usr/local/share/pitainer \
  && node /usr/local/libexec/pitainer/gen-providers.js > /usr/local/share/pitainer/providers.generated \
  && echo "${PI_VERSION}" > /usr/local/share/pitainer/pi-version

ENTRYPOINT ["/usr/local/libexec/pitainer/entrypoint.sh"]
CMD ["pi"]
