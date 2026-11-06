output "vpc_id" {
  description = "Identifier of the StartUpTech VPC"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "Public DNS name of the application load balancer"
  value       = aws_lb.api.dns_name
}

output "bastion_public_ip" {
  description = "Elastic IP address used to connect to the bastion"
  value       = aws_eip.bastion.public_ip
}

output "backend_private_ip" {
  description = "Private IPv4 address of the backend server"
  value       = aws_instance.backend.private_ip
}

output "mongodb_private_ip" {
  description = "Private IPv4 address of the MongoDB server"
  value       = aws_instance.mongodb.private_ip
}
