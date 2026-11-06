terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  sts_region = "us-east-1"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["137112412989"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  common_tags = {
    Project     = "StartupTech"
    Environment = "Assessment"
    ManagedBy   = "Terraform"
  }

  subnets = {
    public_1 = {
      name     = "startuptech-public-subnet-1"
      cidr     = "10.0.1.0/24"
      public   = true
      az_index = 0
    }
    public_2 = {
      name     = "startuptech-public-subnet-2"
      cidr     = "10.0.2.0/24"
      public   = true
      az_index = 1
    }
    private_1 = {
      name     = "startuptech-private-subnet-1"
      cidr     = "10.0.11.0/24"
      public   = false
      az_index = 0
    }
    private_2 = {
      name     = "startuptech-private-subnet-2"
      cidr     = "10.0.12.0/24"
      public   = false
      az_index = 1
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "startuptech-vpc" })
}

resource "aws_subnet" "all" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = data.aws_availability_zones.available.names[each.value.az_index]
  map_public_ip_on_launch = each.value.public

  tags = merge(local.common_tags, {
    Name = each.value.name
    Tier = each.value.public ? "public" : "private"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "startuptech-igw" })
}

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = merge(local.common_tags, { Name = "startuptech-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.all["public_1"].id
  tags          = merge(local.common_tags, { Name = "startuptech-nat-gateway" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "startuptech-public-rt" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "startuptech-private-rt" })
}

resource "aws_route_table_association" "public" {
  for_each = toset(["public_1", "public_2"])

  subnet_id      = aws_subnet.all[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = toset(["private_1", "private_2"])

  subnet_id      = aws_subnet.all[each.key].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "alb" {
  name        = "startuptech-alb-sg"
  description = "Public web ingress for the application load balancer"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "startuptech-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP from the internet"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS from the internet"
}

resource "aws_vpc_security_group_egress_rule" "alb_backend" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Forward requests to the backend"
}


locals {
  bastion_ssh_cidrs = distinct([var.my_ip])
}

resource "aws_security_group" "bastion" {
  name        = "startuptech-bastion-sg"
  description = "SSH access from the current public IP"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "startuptech-bastion-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  for_each          = toset(local.bastion_ssh_cidrs)
  cidr_ipv4         = each.value
  description       = "SSH from the operator current IP or verified alternate egress"
}

resource "aws_vpc_security_group_egress_rule" "bastion_ssh" {
  security_group_id            = aws_security_group.bastion.id
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "SSH to the backend"
}

resource "aws_security_group" "backend" {
  name        = "startuptech-backend-sg"
  description = "Traffic from the load balancer and bastion"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "startuptech-backend-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "backend_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Application traffic from the ALB"
}

resource "aws_vpc_security_group_ingress_rule" "backend_bastion" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "SSH from the bastion"
}

resource "aws_vpc_security_group_egress_rule" "backend_mongodb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.mongodb.id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
  description                  = "MongoDB traffic to the database server"
}

resource "aws_vpc_security_group_egress_rule" "backend_ssh_return" {
  security_group_id = aws_security_group.backend.id
  ip_protocol       = "tcp"
  from_port         = 1024
  to_port           = 65535
  cidr_ipv4         = "${aws_instance.bastion.private_ip}/32"
  description       = "Private SSH responses to the bastion"
}

resource "aws_security_group" "mongodb" {
  name        = "startuptech-mongodb-sg"
  description = "MongoDB access only from the backend security group"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "startuptech-mongodb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "mongodb_backend" {
  security_group_id            = aws_security_group.mongodb.id
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
  description                  = "MongoDB from the backend"
}

resource "aws_vpc_security_group_egress_rule" "package_http" {
  for_each = {
    bastion = aws_security_group.bastion.id
    backend = aws_security_group.backend.id
    mongodb = aws_security_group.mongodb.id
  }

  security_group_id = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP package downloads"
}

resource "aws_vpc_security_group_egress_rule" "package_https" {
  for_each = {
    bastion = aws_security_group.bastion.id
    backend = aws_security_group.backend.id
    mongodb = aws_security_group.mongodb.id
  }

  security_group_id = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS package image and source downloads"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  for_each = {
    bastion = aws_security_group.bastion.id
    backend = aws_security_group.backend.id
    mongodb = aws_security_group.mongodb.id
  }

  security_group_id = each.value
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${cidrhost(aws_vpc.main.cidr_block, 2)}/32"
  description       = "DNS queries to the VPC resolver"
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  for_each = {
    bastion = aws_security_group.bastion.id
    backend = aws_security_group.backend.id
    mongodb = aws_security_group.mongodb.id
  }

  security_group_id = each.value
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "${cidrhost(aws_vpc.main.cidr_block, 2)}/32"
  description       = "DNS responses over TCP"
}

resource "aws_key_pair" "deployment" {
  key_name   = "startuptech-deployment-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
  tags       = merge(local.common_tags, { Name = "startuptech-deployment-key" })
}

resource "aws_instance" "bastion" {
  depends_on = [aws_security_group.management_endpoints, aws_route_table_association.public, aws_route_table_association.private]

  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.all["public_1"].id
  vpc_security_group_ids      = [aws_security_group.bastion.id, aws_security_group.management_endpoints.id]
  iam_instance_profile        = aws_iam_instance_profile.deployment.name
  key_name                    = aws_key_pair.deployment.key_name
  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = "startuptech-bastion", Role = "Bastion" })
}

resource "aws_eip" "bastion" {
  domain     = "vpc"
  instance   = aws_instance.bastion.id
  depends_on = [aws_internet_gateway.main]
  tags       = merge(local.common_tags, { Name = "startuptech-bastion-eip" })
}

resource "aws_instance" "backend" {
  depends_on = [aws_security_group.management_endpoints, aws_route_table_association.public, aws_route_table_association.private]

  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.all["private_1"].id
  vpc_security_group_ids      = [aws_security_group.backend.id, aws_security_group.management_endpoints.id]
  iam_instance_profile        = aws_iam_instance_profile.deployment.name
  key_name                    = aws_key_pair.deployment.key_name
  user_data                   = file("${path.module}/user_data/backend_setup.sh")
  user_data_replace_on_change = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = "startuptech-backend", Role = "Backend" })
}

resource "aws_instance" "mongodb" {
  depends_on = [aws_security_group.management_endpoints, aws_route_table_association.public, aws_route_table_association.private]

  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.all["private_2"].id
  vpc_security_group_ids      = [aws_security_group.mongodb.id, aws_security_group.management_endpoints.id]
  iam_instance_profile        = aws_iam_instance_profile.deployment.name
  key_name                    = aws_key_pair.deployment.key_name
  private_ip                  = cidrhost(aws_subnet.all["private_2"].cidr_block, 10)
  user_data                   = templatefile("${path.module}/user_data/mongodb_setup.sh", { private_ip = cidrhost(aws_subnet.all["private_2"].cidr_block, 10) })
  user_data_replace_on_change = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.common_tags, { Name = "startuptech-mongodb", Role = "MongoDB" })
}

resource "aws_security_group" "instance_connect" {
  name        = "startuptech-instance-connect-sg"
  description = "Bastion only SSH egress for the identity aware tunnel endpoint"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "startuptech-instance-connect-sg" })
}

resource "aws_vpc_security_group_egress_rule" "instance_connect_bastion" {
  security_group_id            = aws_security_group.instance_connect.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "SSH only to the bastion, through the managed private tunnel"
}

resource "aws_vpc_security_group_ingress_rule" "bastion_instance_connect" {
  security_group_id            = aws_security_group.bastion.id
  referenced_security_group_id = aws_security_group.instance_connect.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "SSH only from the managed Instance Connect endpoint"
}

resource "aws_ec2_instance_connect_endpoint" "bastion" {
  subnet_id          = aws_subnet.all["public_1"].id
  security_group_ids = [aws_security_group.instance_connect.id]
  preserve_client_ip = false
  tags               = merge(local.common_tags, { Name = "startuptech-bastion-tunnel" })
}

resource "aws_security_group" "management_endpoints" {
  name        = "startuptech-management-endpoints-sg"
  description = "Private HTTPS only for EC2 systems agent communications"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.common_tags, { Name = "startuptech-management-endpoints-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "management_host" {
  for_each = {
    bastion = aws_security_group.bastion.id
    backend = aws_security_group.backend.id
    mongodb = aws_security_group.mongodb.id
  }
  security_group_id            = aws_security_group.management_endpoints.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "System management traffic from an assessment instance"
}

resource "aws_vpc_security_group_egress_rule" "management_host" {
  for_each = {
    bastion = aws_security_group.bastion.id
    backend = aws_security_group.backend.id
    mongodb = aws_security_group.mongodb.id
  }
  security_group_id            = aws_security_group.management_endpoints.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "System management responses to an assessment instance"
}

resource "aws_vpc_endpoint" "management" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.all["private_1"].id]
  security_group_ids  = [aws_security_group.management_endpoints.id]
  private_dns_enabled = true
  tags = merge(local.common_tags, {
    Name = "startuptech-${each.value}-endpoint"
  })
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deployment" {
  name               = "startuptech-deployment-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = merge(local.common_tags, { Name = "startuptech-deployment-role" })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.deployment.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "deployment" {
  name = "startuptech-deployment-profile"
  role = aws_iam_role.deployment.name
  tags = merge(local.common_tags, { Name = "startuptech-deployment-profile" })
}

resource "aws_lb" "api" {
  name               = "startuptech-api-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.all["public_1"].id, aws_subnet.all["public_2"].id]

  tags = merge(local.common_tags, { Name = "startuptech-api-alb" })
}

resource "aws_lb_target_group" "backend" {
  name        = "startuptech-backend-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    port                = "8080"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "startuptech-backend-tg" })
}

resource "aws_lb_target_group_attachment" "backend" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.backend.id
  port             = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
