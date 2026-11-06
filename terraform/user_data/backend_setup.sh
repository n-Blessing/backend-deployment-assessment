#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/backend_setup.log) 2>&1

for attempt in {1..12}; do
  if curl --fail --silent --show-error --connect-timeout 10 --max-time 30     "https://amazonlinux-2-repos-eu-west-1.s3.dualstack.eu-west-1.amazonaws.com/2/core/latest/x86_64/mirror.list"     --output /dev/null; then
    break
  fi
  echo "Waiting for the private subnet NAT route, attempt ${attempt}"
  sleep 10
done

yum -y --setopt=timeout=30 --setopt=retries=10 install docker git openssl

systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

COMPOSE_VERSION="v2.40.3"
mkdir -p /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
curl --fail --location --retry 5 \
  "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  --output /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

BUILDX_VERSION="v0.30.1"
curl --fail --location --retry 5 \
  "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
  --output /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
ln -sf /usr/local/lib/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

docker compose version
docker buildx version
