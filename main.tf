#############################################################
# AWS INFRASTRUCTURE AUTOMATED WITH TERRAFORM — SINGLE FILE
#
# This one file provisions:
#   1. A VPC with a public subnet
#   2. An Internet Gateway + route table (so the subnet can reach the internet)
#   3. A Security Group (SSH locked to your IP, HTTP open)
#   4. An IAM role + instance profile (least-privilege, S3 read-only)
#   5. An EC2 instance running Apache (a simple web server)
#   6. An S3 bucket (versioned, encrypted, private)
#
# Everything is in one file for simplicity while you're learning.
# Once you're comfortable, splitting into multiple files (vpc.tf,
# ec2.tf, s3.tf, variables.tf...) is the more "professional" pattern —
# mention this in your README/interview to show you know both.
#############################################################


#############################################################
# 1. TERRAFORM + PROVIDER SETUP
# This tells Terraform which cloud provider to talk to (AWS),
# and which version of the AWS provider plugin to use.
#############################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}


#############################################################
# 2. VARIABLES
# Variables let you reuse this file for different setups without
# editing the code itself — you just change values in terraform.tfvars.
#############################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1" # Mumbai — closest region if you're in India
}

variable "project_name" {
  description = "Name prefix used to tag and name all resources"
  type        = string
  default     = "resume-project"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (the private IP range for this network)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (a smaller slice of the VPC range)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type — keep this free-tier eligible"
  type        = string
  default     = "t3.micro"
}

variable "my_ip" {
  description = "YOUR public IP in CIDR form, e.g. 1.2.3.4/32. Find yours at https://whatismyip.com. Used to restrict SSH so only you can log in — never leave this open to 0.0.0.0/0."
  type        = string
  # No default on purpose — Terraform will refuse to run until you set
  # this yourself in terraform.tfvars. That's intentional, it forces
  # you to think about it instead of copy-pasting an insecure default.
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name. S3 names are unique across ALL of AWS, not just your account, so add your name/date, e.g. 'yourname-terraform-demo-2026'"
  type        = string
  # No default on purpose — same reasoning as my_ip above.
}


#############################################################
# 3. NETWORKING — VPC, SUBNET, INTERNET GATEWAY, ROUTING
#############################################################

# The VPC is your own private, isolated network inside AWS.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# We need to know which Availability Zones exist in this region
# so we can place our subnet in one of them.
data "aws_availability_zones" "available" {
  state = "available"
}

# The public subnet is a slice of the VPC where resources CAN get
# a public IP and reach the internet (via the Internet Gateway below).
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block               = var.public_subnet_cidr
  map_public_ip_on_launch  = true
  availability_zone        = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

# The Internet Gateway is what actually connects your VPC to the internet.
# Without this, nothing inside the VPC could reach (or be reached from)
# the outside world, no matter how the subnet is configured.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# A route table is a set of rules that says "traffic going to X, send it via Y."
# Here: "traffic going anywhere (0.0.0.0/0), send it out via the Internet Gateway."
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# This actually attaches (associates) the route table to our subnet.
# A route table with no association does nothing.
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}


#############################################################
# 4. SECURITY GROUP — acts as a firewall for the EC2 instance
#############################################################

resource "aws_security_group" "web" {
  name        = "${var.project_name}-sg"
  description = "Allow restricted SSH and open HTTP"
  vpc_id      = aws_vpc.main.id

  # Only YOUR IP can SSH in — this is the #1 thing interviewers check for.
  # Opening port 22 to 0.0.0.0/0 (the whole internet) is a classic
  # beginner mistake and a real security risk.
  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  # HTTP is open to everyone, because this is a public web server —
  # that's intentional, not a mistake, and it's worth explaining that
  # distinction in an interview.
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound traffic — the instance can reach anywhere (needed for updates, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}


#############################################################
# 5. IAM ROLE — least-privilege permissions for the EC2 instance
#
# Instead of putting AWS access keys ON the server (a common mistake),
# we attach a ROLE. AWS handles the credentials automatically and
# securely behind the scenes. The role only allows READING from our
# one specific S3 bucket — nothing else. This is "least privilege,"
# and it's one of the most interview-worthy things in this project.
#############################################################

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  # This policy says "EC2 instances are allowed to assume this role."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# This is the actual permission: read + list objects, ONLY on our bucket.
resource "aws_iam_role_policy" "s3_read_only" {
  name = "${var.project_name}-s3-read-only"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.demo.arn,
        "${aws_s3_bucket.demo.arn}/*"
      ]
    }]
  })
}

# An instance profile is just the "container" that lets an EC2 instance
# actually use an IAM role — AWS requires this extra wrapper.
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}


#############################################################
# 6. EC2 INSTANCE — the actual virtual server
#############################################################

# Rather than hardcoding an AMI ID (which changes over time and differs
# per region), we ask AWS for the latest Amazon Linux 2023 AMI at apply
# time. This is a small detail that shows you understand AMIs aren't
# static, a common gap for beginners.
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  # user_data runs automatically the FIRST time the instance boots.
  # Here it installs and starts Apache, then writes a simple test page,
  # so you have visible proof the server works the moment it's up.
  user_data = <<-EOF
              #!/bin/bash
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Deployed with Terraform by ${var.project_name}</h1>" > /var/www/html/index.html
              EOF

  tags = {
    Name = "${var.project_name}-web"
  }
}


#############################################################
# 7. S3 BUCKET — versioned, encrypted, private storage
#############################################################

resource "aws_s3_bucket" "demo" {
  bucket = var.bucket_name

  tags = {
    Name = "${var.project_name}-bucket"
  }
}

# Versioning means if a file gets overwritten or deleted, old versions
# are kept and recoverable — a real-world backup/safety practice.
resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypts everything stored in the bucket at rest, automatically.
resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Blocks ALL public access to the bucket, at every level. This is AWS's
# own recommended default, and having it explicitly here (instead of
# relying on account defaults) is a good, deliberate security signal.
resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


#############################################################
# 8. OUTPUTS — printed to your terminal after `terraform apply`
#############################################################

output "ec2_public_ip" {
  description = "Public IP of the web server — open this in a browser to see it working"
  value       = aws_instance.web.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS name of the web server"
  value       = aws_instance.web.public_dns
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket created"
  value       = aws_s3_bucket.demo.id
}

output "vpc_id" {
  description = "ID of the VPC created"
  value       = aws_vpc.main.id
}
