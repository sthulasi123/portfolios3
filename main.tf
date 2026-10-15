
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Use AWS CLI credentials; do not hardcode access keys
provider "aws" {
  region = "ap-south-1"
 
}

variable "bucket_name" {
  description = "S3 bucket containing portfolio files"
  type        = string
  default     = "terraform-bucket1537"
}

# 1. Default VPC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 2. Latest Ubuntu 24.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 3. Upload index.html
resource "aws_s3_object" "index" {
  bucket       = var.bucket_name
  key          = "index.html"
  source       = "${path.module}/index.html"
  etag         = filemd5("${path.module}/index.html")
  content_type = "text/html"
}

# 4. Optional portfolio assets
locals {
  optional_files = {
    for name in ["style.css", "script.js", "thulasi.jpg"] :
    name => name
    if fileexists("${path.module}/${name}")
  }

  content_types = {
    "style.css"   = "text/css"
    "script.js"   = "application/javascript"
    "thulasi.jpg" = "image/jpeg"
  }
}

resource "aws_s3_object" "assets" {
  for_each = local.optional_files

  bucket       = var.bucket_name
  key          = each.key
  source       = "${path.module}/${each.value}"
  etag         = filemd5("${path.module}/${each.value}")
  content_type = local.content_types[each.key]
}

# 5. EC2 IAM role
resource "aws_iam_role" "ec2_role" {
  name = "portfolio-ec2-s3-read-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# 6. Allow EC2 to read portfolio files from S3
resource "aws_iam_role_policy" "s3_read" {
  name = "portfolio-s3-read-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.bucket_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.bucket_name}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "portfolio-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# 7. HTTP Security Group

# Security Group for Portfolio Nginx EC2

# 7. Security Group for Portfolio EC2
resource "aws_security_group" "web_sg" {
  name_prefix = "portfolio-nginx-"
  description = "Allow SSH, HTTP and HTTPS access"
  vpc_id      = data.aws_vpc.default.id

  # SSH - restrict access to your own public IP
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["65.0.60.120/32"]
  }

  # HTTP - portfolio website
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "portfolio-web-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 8. EC2 with automatic Nginx and website setup
resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail

exec > >(tee -a /var/log/portfolio-setup.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

# Update package index and install required packages
apt-get update -y
apt-get install -y nginx curl unzip
# Install AWS CLI v2
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
aws --version

# Ensure website directory exists
mkdir -p /var/www/html
rm -f /var/www/html/index.nginx-debian.html

# Retry S3 sync to allow time for EC2 IAM credentials
for attempt in $(seq 1 12); do
  if aws s3 sync s3://${var.bucket_name}/ /var/www/html/ \
      --delete --region ap-south-1; then
    break
  fi

  if [ "$attempt" -eq 12 ]; then
    echo "ERROR: S3 sync failed after retries"
    exit 1
  fi

  sleep 10
done

# Check that the main website file exists
test -s /var/www/html/index.html

# Set permissions
chown -R www-data:www-data /var/www/html

# Validate and start Nginx
nginx -t
systemctl enable nginx
systemctl restart nginx

# Verify local HTTP response
curl --retry 5 --retry-delay 2 --fail http://localhost/
EOF

  user_data_replace_on_change = true

  depends_on = [
    aws_iam_role_policy.s3_read,
    aws_s3_object.index,
    aws_s3_object.assets
  ]

  tags = {
    Name = "Thulasi-Portfolio-WebServer"
  }
}

# 9. Outputs
output "portfolio_public_ip" {
  description = "EC2 public IPv4 address"
  value       = aws_instance.web.public_ip
}

output "portfolio_url" {
  description = "Portfolio website URL"
  value       = "http://${aws_instance.web.public_ip}"
}