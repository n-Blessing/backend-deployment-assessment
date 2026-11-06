# StartupTech backend deployment

This project provisions the infrastructure for the MuchTodo Go API and runs the application with Docker Compose. The AWS region is Ireland, eu west 1. Cape Town was not available for this account. Internet traffic reaches the Application Load Balancer on port 80. The load balancer sends health requests to the backend on port 8080. SSH access is restricted to the public IP supplied through the my_ip variable.

The Compose stack contains the API and MongoDB on a private bridge network. MongoDB uses a named volume for persistence. Terraform also provisions the separate MongoDB EC2 server required by the assessment. Compose uses its own MongoDB container, so the separate server does not claim the same database storage.

## Architecture

1. A VPC named `startuptech-vpc` uses the 10.0.0.0/16 address range with DNS support and DNS hostnames enabled.
2. Two public subnets and two private subnets span two availability zones.
3. An internet gateway serves the public subnets. A NAT gateway gives private instances outbound access.
4. Three Amazon Linux 2 instances use the t3.micro type. The bastion has an Elastic IP. The backend and MongoDB instances have private addresses.
5. The Application Load Balancer forwards HTTP requests to the backend target group. Its health check uses /health and accepts HTTP 200.
6. Security groups limit each connection to its required source and destination.
7. The SSH public key is uploaded as an EC2 key pair. The private key never enters Terraform state.

## Prerequisites

1. An AWS account with permissions for EC2, VPC, Elastic IP, NAT Gateway, and Elastic Load Balancing.
2. AWS CLI version 2 configured with valid credentials.
3. Terraform version 1.6 or newer.
4. Docker Engine with Buildx and Docker Compose version 2.40 or newer.
5. Git, curl, OpenSSH, and Python 3.
6. Internet access to download the application, providers, base images, and packages.

AWS credentials must stay outside this repository. Configure the AWS CLI with aws configure, or export credentials in the shell that runs Terraform. Never place AWS credentials in Terraform files. This account requires its STS account lookup in us east 1 while resources remain in Ireland. The provider therefore uses the explicit sts_region setting.

The NAT gateway, Elastic IP addresses, EC2 instances, EBS storage, and load balancer can incur charges. Stop charges by completing the teardown section when the assessment is finished.

## Repository layout

```text
terraform/main.tf
terraform/variables.tf
terraform/outputs.tf
terraform/terraform.tfvars.example
terraform/user_data/backend_setup.sh
terraform/user_data/mongodb_setup.sh
Dockerfile
docker-compose.yml
.dockerignore
.gitignore
evidence/
README.md
```

## Prepare local settings

Clone this repository and enter its directory.

```bash
git clone <YOUR_REPOSITORY_URL>
cd backend-deployment-assessment
```

Generate an SSH key pair if you do not already have one.

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/startuptech_key
chmod 600 ~/.ssh/startuptech_key
```

Find your current public IPv4 address.

```bash
curl -4 https://api.ipify.org
```

Create the variables file from the example.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit terraform/terraform.tfvars. Replace the example address with your own IPv4 address with the slash thirty two suffix. Set `ssh_public_key_path` to the generated public key. Confirm that `aws_region` matches the Ireland region in the example.

The application JWT secret is supplied only at runtime. Generate it locally with Python or with OpenSSL on the EC2 instance.

```bash
export JWT_SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
printf '%s\n' "$JWT_SECRET_KEY"
```

Keep the generated value private. It is not stored in this project. Each terminal session that runs Compose needs this variable.

## Provision AWS infrastructure

Review the configuration.

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init
terraform -chdir=terraform validate
```

Create the execution plan.

```bash
terraform -chdir=terraform plan -out=terraform/assessment.tfplan
```

Check that the plan shows the expected VPC, four subnets, gateways, route tables, four security groups, three instances, key pair, Elastic IP addresses, load balancer, target group, target attachment, and listener.

Apply the saved plan.

```bash
terraform -chdir=terraform apply terraform/assessment.tfplan
```

Read the deployment endpoints.

```bash
terraform -chdir=terraform output vpc_id
terraform -chdir=terraform output alb_dns_name
terraform -chdir=terraform output bastion_public_ip
terraform -chdir=terraform output backend_private_ip
```

No SSH private key is printed or stored by these commands. The key remains in the local SSH directory.

## Build and test locally

The Dockerfile has two stages. The builder reads the supplied Git source at a pinned commit. Its configuration patch binds every declared Viper setting to the environment expected by the application. The runtime contains only the compiled application, certificates, curl, and the non root application account. Its health command requests /health on port 8080.

Build with the same named source context that Compose defines.

```bash
docker buildx build \
  --build-context source=https://github.com/Innocent9712/much-to-do.git#c483fda7d1c1f6c996a95de5343cba026e932706:Server/MuchToDo \
  --tag muchtodo-backend:assessment \
  --load .
```

Alternatively let Compose run the build.

```bash
docker compose build
```

Start both services and inspect them.

```bash
docker compose up -d
docker compose ps
```

Docker waits for MongoDB to pass its health check before starting the API. Check the endpoint and logs.

```bash
curl -i http://localhost:8080/health
docker compose logs backend
docker compose logs mongodb
```

The expected status is HTTP 200 with database equal to ok and cache equal to disabled.

Inspect that the runtime user is numeric rather than root.

```bash
docker image inspect muchtodo-backend:assessment --format '{{.Config.User}}'
```

The expected output is 10001:10001.

## Deploy on the backend EC2 instance

Read the public and private addresses into shell variables.

```bash
BASTION_IP="$(terraform -chdir=terraform output -raw bastion_public_ip)"
BACKEND_IP="$(terraform -chdir=terraform output -raw backend_private_ip)"
ALB_DNS="$(terraform -chdir=terraform output -raw alb_dns_name)"
KEY="$HOME/.ssh/startuptech_key"
export BASTION_IP BACKEND_IP ALB_DNS KEY
```

Connect through the bastion with ProxyJump.

```bash
ssh -i "$KEY" \
  -o StrictHostKeyChecking=accept-new \
  -J "ec2-user@$BASTION_IP" \
  "ec2-user@$BACKEND_IP"
```

Remain on the backend instance for the following commands.

Clone the supplied application branch as required by the brief.

```bash
mkdir -p ~/deployment
cd ~/deployment
git clone --branch feature/backend-only --single-branch https://github.com/Innocent9712/much-to-do.git application
```

Exit the SSH session and copy the two deployment files into that directory.

```bash
exit
scp -i "$KEY" -o ProxyJump="ec2-user@$BASTION_IP" \
  Dockerfile docker-compose.yml \
  "ec2-user@$BACKEND_IP:/home/ec2-user/deployment/"
```

Start a fresh SSH session.

```bash
ssh -i "$KEY" -J "ec2-user@$BASTION_IP" "ec2-user@$BACKEND_IP"
cd ~/deployment
export JWT_SECRET_KEY="$(openssl rand -base64 48)"
sudo --preserve-env=JWT_SECRET_KEY docker compose up -d
sudo --preserve-env=JWT_SECRET_KEY docker compose ps
curl -i http://localhost:8080/health
cd ~/deployment/application/Server/MuchToDo
```

At that last directory, the application branch cloned onto the backend is visible. The working deployment files are one directory above the application clone at /home/ec2-user/deployment.

For future Compose commands in another session, generate another secret and pass it through sudo with the same environment option. The original secret must remain unchanged during server restarts if existing JWT tokens must stay valid. A secret manager is recommended outside this assessment.

Leave the backend session when both containers are running.

```bash
exit
```

Test the public route from your workstation.

```bash
curl -i "http://$ALB_DNS/health"
```

A successful response has status HTTP 200. The target group may need a few minutes to become healthy.

For installation diagnostics, inspect backend_setup.log or mongodb_setup.log in the /var/log directory. Database traffic to the MongoDB EC2 instance is allowed only from the backend security group. The Compose application continues to use its private container database on the backend.

## Low-memory deployment transport option

The normal `Dockerfile` and Compose `source` context compile the pinned upstream commit inside Docker. On a constrained `t3.micro`, a prebuilt binary made from that same commit (including the Viper configuration patch) can instead be loaded into the runtime image before the backend runs Compose. The `Dockerfile.runtime` uses the same Alpine runtime, UID `10001:10001`, port, healthcheck, and entrypoint. It is a transport optimization, not a different application configuration.

To do this, put the verified executable named `muchtodo` in `/home/ec2-user/runtime`, copy `Dockerfile.runtime` to `/home/ec2-user/runtime/Dockerfile`, and put the supplied `docker-compose.runtime.yml` alongside the main deployment Compose file. Then run:

```bash
cd /home/ec2-user/deployment
docker build --tag muchtodo-backend:assessment /home/ec2-user/runtime
docker compose -f docker-compose.yml -f docker-compose.runtime.yml up -d
```

Compose creates the API and its healthy MongoDB dependency with the same named persistent volume and runtime `.env`. Do not copy `.env`, a private SSH key, the real `terraform/terraform.tfvars`, or binary build products into the source archive. The application source remains pinned at `c483fda7d1c1f6c996a95de5343cba026e932706`.

## Terraform state

Terraform uses local state for this assessment. The state can include public and private addresses, account identifiers, and security group configuration. Review it before sharing.

```bash
python3 - <<'PY'
import json
from pathlib import Path
state = json.loads(Path('terraform/terraform.tfstate').read_text())
text = json.dumps(state)
blocked = ['BEGIN ' + 'PRIVATE KEY', 'AWS_SECRET_ACCESS_KEY', 'JWT_SECRET_KEY']
assert not any(item in text for item in blocked)
for resource in state.get('resources', []):
    assert resource.get('type') != 'tls_private_key'
print('State secret review passed')
PY
cp terraform/terraform.tfstate terraform.tfstate
```

The root state export must be included with the submission as requested by the brief. The original state must remain in the Terraform working directory for future applies and teardown.

## Stop local containers

Stop only the local Compose project without deleting its database volume.

```bash
docker compose down
```

If a reset of the local database is intentionally required, include the volume flag.

```bash
docker compose down --volumes
```

## Teardown AWS resources

After saving all evidence and receiving any required review, remove the AWS resources to stop ongoing charges.

```bash
terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
```

Do not run destroy while the live backend is needed for assessment evidence or review. Also disable or delete the temporary AWS access key after the work is complete. Keep the private SSH key local and never commit it.
