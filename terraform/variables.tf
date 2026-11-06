variable "aws_region" {
  description = "AWS region where the infrastructure is provisioned"
  type        = string
  default     = "eu-west-1"
}

variable "instance_type" {
  description = "EC2 instance type for the bastion backend and MongoDB servers"
  type        = string
  default     = "t3.micro"
}

variable "my_ip" {
  description = "Current public IPv4 address in CIDR notation for bastion SSH access"
  type        = string

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.my_ip))
    error_message = "Provide one public IPv4 address followed by /32."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the local SSH public key uploaded as the EC2 key pair"
  type        = string
  default     = "/home/YOUR_USER/.ssh/startuptech_key.pub"
}

