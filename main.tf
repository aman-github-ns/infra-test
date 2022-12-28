terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "ap-south-1"
}

provider "aws" {
  alias  = "acm_provider"
  region = "us-east-1"
}


##### -------------------- FRONTEND -------------------- ##### 

#S3 BUCKET
resource "aws_s3_bucket" "prod-fe-bucket" {
  bucket = "ekobon-prod"
  tags = {
    Environment = "Production"
  }
}

#S3 BUCKET POLICY
resource "aws_s3_bucket_policy" "prod-bucket-policy" {
  bucket = aws_s3_bucket.prod-fe-bucket.id
  policy = file("bucket-policy.json")
}

#S3 WEBSITE CONFIGURATION
resource "aws_s3_bucket_website_configuration" "prod-fe-bucket-website-config" {
  bucket = aws_s3_bucket.prod-fe-bucket.bucket

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }

}

#CERTIFICATE FOR FRONTEND CLOUDFRONT

#certificate
resource "aws_acm_certificate" "prod_fe_acm_cert" {
  provider          = aws.acm_provider
  domain_name       = "ekobon.com"
  validation_method = "DNS"
}

#Get the hosted zone ( Created manually from console )
data "aws_route53_zone" "route53_hosted_zone" {
  name         = "ekobon.com"
  private_zone = false
}

#Certificate Validation
resource "aws_route53_record" "route53_record" {
  for_each = {
    for r in aws_acm_certificate.prod_fe_acm_cert.domain_validation_options : r.domain_name => {
      name   = r.resource_record_name
      record = r.resource_record_value
      type   = r.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.route53_hosted_zone.zone_id
}

resource "aws_acm_certificate_validation" "acm_cert_fe_validation" {
  provider                = aws.acm_provider
  certificate_arn         = aws_acm_certificate.prod_fe_acm_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.route53_record : record.fqdn]
}

#CREATE CLOUDFRONT DISTRIBUTION

locals {
  s3_origin_id = "prod-s3-origin"
}

resource "aws_cloudfront_distribution" "prod_s3_cf_distribution" {
  origin {
    domain_name       = aws_s3_bucket.prod-fe-bucket.bucket_regional_domain_name
    origin_id         = local.s3_origin_id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["ekobon.com"]
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    compress=true
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    cache_policy_id="658327ea-f89d-4fab-a63d-7e88639e58f6"

    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
        }
  }

  custom_error_response {
    error_caching_min_ttl=0
    error_code=403
    response_code=200
    response_page_path="/index.html"
  }

  custom_error_response {
    error_caching_min_ttl=0 
    error_code=404
    response_code=200
    response_page_path="/index.html"
  }
  
    tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    acm_certificate_arn = aws_acm_certificate.prod_fe_acm_cert.arn
    ssl_support_method = "sni-only"
  }

  wait_for_deployment=false
}

##Create record and link to CF
# resource "aws_route53_record" "route53_prod_fe_cf_record" {
#   zone_id = data.aws_route53_zone.route53_hosted_zone.zone_id
#   name    = "ekobon.com"
#   type    = "A"
#   alias {
#     name  = aws_cloudfront_distribution.prod_s3_cf_distribution.domain_name
#     zone_id = aws_cloudfront_distribution.prod_s3_cf_distribution.hosted_zone_id
#     evaluate_target_health = true
#   }
# }



##### -------------------- BACKEND -------------------- ##### 

#VPC FOR BACKEND
resource "aws_vpc" "vpc_prod_backend" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Environment = "production"
  }
}

#SUBNETS  - Creating 2 public subnets

variable "azs" {
 type        = list(string)
 description = "Availability Zones"
 default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
 type        = list(string)
 description = "Public Subnet CIDR values"
 default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

resource "aws_subnet" "public_subnets" {
 count      = length(var.public_subnet_cidrs)
 vpc_id     = aws_vpc.vpc_prod_backend.id
 cidr_block = element(var.public_subnet_cidrs, count.index)
 availability_zone = element(var.azs, count.index)

 tags = {
   Name = "Public Subnet Production Backend ${count.index + 1}"
 }
}

#Internet gateway for VPC

resource "aws_internet_gateway" "gateway_prod_backend" {
  vpc_id = aws_vpc.vpc_prod_backend.id

  tags = {
    Environment = "production"
  }
}

#Creating a route table. This route table will be linked with IG and associate to subnets

resource "aws_route_table" "custom_route_table_prod_backend_vpc" {
 vpc_id = aws_vpc.vpc_prod_backend.id
 
 route {
   cidr_block = "0.0.0.0/0"
   gateway_id = aws_internet_gateway.gateway_prod_backend.id
 }
 
 tags = {
    Environment = "production"
 }
}

#Associate  subnets with route table

resource "aws_route_table_association" "public_subnet_asso_prod_backend" {
 count = length(var.public_subnet_cidrs)
 subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
 route_table_id = aws_route_table.custom_route_table_prod_backend_vpc.id
}

#Creating EC2 backend server

#Security group for ec2 instance 

locals {
  ports_in_ec2 = [
    443,
    80,
    8080,
    19999,
    3000,
    22
  ]
  ports_out_ec2 = [
    0
  ]
}

resource "aws_security_group" "prod_backend_ec2_sg" {
  name        = "prod_backend_ec2_sg"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.vpc_prod_backend.id

  dynamic "ingress" {
    for_each = toset(local.ports_in_ec2)
    content {
      description = "Web Traffic from internet"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  dynamic "egress" {
    for_each = toset(local.ports_out_ec2)
    content {
      description = "Web Traffic to internet"
      from_port   = egress.value
      to_port     = egress.value
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = {
    Environment = "Production"
  }
}


## EC2
  
resource "aws_instance" "prod_backend_ec2" {
  ami           = "ami-07ffb2f4d65357b42"
  instance_type = "t3a.small"
  subnet_id = aws_subnet.public_subnets[0].id
  vpc_security_group_ids = [aws_security_group.prod_backend_ec2_sg.id]
  root_block_device {
    volume_size = 60
  }
  key_name="ekobon-backend-server"
  tags = {
    Name = "production-backend"
  }
  user_data = file("startup_script.sh")
  
}

resource "aws_eip" "prod_backend_ec2_eip" {
  instance = aws_instance.prod_backend_ec2.id
  vpc      = false
}

#Creating Load balancer
#Security group for load balancer

locals {
  ports_in_alb = [
    443,
    80
  ]
  ports_out_alb = [
    0
  ]
}


resource "aws_security_group" "prod_backend_lb_sg" {
  name        = "prod_backend_lb_sg"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.vpc_prod_backend.id

  dynamic "ingress" {
    for_each = toset(local.ports_in_alb)
    content {
      description = "Web Traffic from internet"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  dynamic "egress" {
    for_each = toset(local.ports_out_alb)
    content {
      description = "Web Traffic to internet"
      from_port   = egress.value
      to_port     = egress.value
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = {
    Environment = "Production"
  }
}

#Creating Load balancer
resource "aws_lb" "prod_be_alb" {
  name               = "prod-backend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.prod_backend_lb_sg.id]
  subnets            =  aws_subnet.public_subnets.*.id
  ip_address_type    = "ipv4"

  enable_deletion_protection = false

  tags = {
    Environment = "production"
  }
}

#Creating Target group
resource "aws_lb_target_group" "prod_be_lb_tg" {
	name	= "prod-be-lb-tg"
	vpc_id	= aws_vpc.vpc_prod_backend.id
	port	= "80"
	protocol	= "HTTP"
	health_check {
                path = "/"
                protocol = "HTTP"
                healthy_threshold = 2
                unhealthy_threshold = 2
                interval = 5
                timeout = 4
                matcher = "200"
        }
}
#Associate target group to ec2
resource "aws_lb_target_group_attachment" "prod_be_tg_ec2_attach" {
  target_group_arn = aws_lb_target_group.prod_be_lb_tg.arn
  target_id        = aws_instance.prod_backend_ec2.id
  port             = 3000
}

#CERTIFICATE FOR LB

resource "aws_acm_certificate" "prod_be_acm_cert" {
  domain_name       = "backend.ekobon.com"
  validation_method = "DNS"
}

resource "aws_route53_record" "route53_record_be" {
  for_each = {
    for b in aws_acm_certificate.prod_be_acm_cert.domain_validation_options : b.domain_name => {
      name   = b.resource_record_name
      record = b.resource_record_value
      type   = b.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.route53_hosted_zone.zone_id
}

resource "aws_acm_certificate_validation" "acm_cert_be_validation" {
  certificate_arn         = aws_acm_certificate.prod_be_acm_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.route53_record_be : record.fqdn]
}

#Listeners for Lb

## http listener
resource "aws_lb_listener" "prod_be_alb_listener_http" {
  load_balancer_arn = aws_lb.prod_be_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type          = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

#https listener
resource "aws_lb_listener" "prod_be_alb_listener_https" {
  load_balancer_arn = aws_lb.prod_be_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.prod_be_acm_cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod_be_lb_tg.arn
  }
}

#Creating backend route 53 record and linking to load balancer
resource "aws_route53_record" "prod_backend_route53_record" {
  zone_id = data.aws_route53_zone.route53_hosted_zone.zone_id
  name    = "backend.ekobon.com"
  type    = "A"

  alias {
    name                   = aws_lb.prod_be_alb.dns_name
    zone_id                = aws_lb.prod_be_alb.zone_id
    evaluate_target_health = true
  }
}

## add elastic ip  -- done
##add user data to install docker and docker compose -- done

## user data to clone backend repo

## setup BE
## automate BE deployment - How to handle migrations
## structure terraform project structure (modules, variable files)
## create acm , record, ALB  -- done
## deploy and test
## link FE CF to Route53 -- done
## prod codepipeline
## move other environments to Terraform
## monitoring setup of production and qa ( memory, ram , cpu )
## logs to debug
## handle base url in FE
## handle environment file in BE, docker env
## move codepipeline to git repo
## security groups 

## automate backup of postrges db - ebs backup , store dump on s3
## terraform remote state file



