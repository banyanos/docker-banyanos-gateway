#!/bin/sh
# Docker Desktop exposes file secrets with permissive modes. Copy the Git key
# to a private, ephemeral path for OpenSSH; never bake it into an image.
set -eu
if [ -s /run/secrets/github_ssh_key ]; then
    umask 077
    mkdir -p /tmp/gateway-git
    cp /run/secrets/github_ssh_key /tmp/gateway-git/id_ed25519
    chmod 600 /tmp/gateway-git/id_ed25519
    export GIT_SSH_COMMAND='ssh -i /tmp/gateway-git/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes'
fi
exec "$@"
