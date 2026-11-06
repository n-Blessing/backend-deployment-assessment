#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/mongodb_setup.log) 2>&1

cat > /etc/yum.repos.d/mongodb-org-7.0.repo <<'REPO'
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/7.0/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-7.0.asc
REPO

for attempt in {1..12}; do
  if curl --fail --silent --show-error --connect-timeout 10 --max-time 30     "https://amazonlinux-2-repos-eu-west-1.s3.dualstack.eu-west-1.amazonaws.com/2/core/latest/x86_64/mirror.list"     --output /dev/null; then
    break
  fi
  echo "Waiting for the private subnet NAT route, attempt $${attempt}"
  sleep 10
done

yum -y --setopt=timeout=30 --setopt=retries=10 install mongodb-org
sed -i 's/  bindIp: 127.0.0.1/  bindIp: 127.0.0.1,${private_ip}/' /etc/mongod.conf
systemctl enable mongod
systemctl restart mongod
systemctl --no-pager --full status mongod
