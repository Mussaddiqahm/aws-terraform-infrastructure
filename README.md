# AWS Infrastructure Automated with Terraform

Provisions a small, secure AWS environment using Terraform instead of the
AWS Console — a VPC with public networking, an EC2 web server with a
least-privilege IAM role, and a versioned, encrypted S3 bucket, all defined
as reusable, version-controlled infrastructure code.

## What this deploys

| Resource | Purpose |
|---|---|
| VPC + public subnet | Isolated network |
| Internet Gateway + route table | Public internet access for the subnet |
| Security Group | SSH restricted to a single IP, HTTP open |
| EC2 instance (Amazon Linux 2023) | Runs Apache, serves a test page |
| IAM role + instance profile | Least-privilege, read-only S3 access for the EC2 instance |
| S3 bucket | Versioning + AES256 encryption + public access blocked |

## Architecture

```
                    Internet
                        |
                 Internet Gateway
                        |
                 +------+------+
                 |     VPC     |   10.0.0.0/16
                 |  +-------+  |
                 |  |Public |  |   10.0.1.0/24
                 |  |Subnet |  |
                 |  |       |  |
                 |  |  EC2  |--+-- IAM Role (S3 read-only)
                 |  | (web) |  |
                 |  +-------+  |
                 +-------------+

                 S3 Bucket (versioned, encrypted, private)
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [AWS CLI](https://aws.amazon.com/cli/), configured with `aws configure`
  using a dedicated IAM user (not root) with programmatic access
- An AWS account (Free Tier covers this project if resources are destroyed
  when not actively in use)

## How to run it

```bash
# 1. Clone the repo
git clone <this-repo-url>
cd aws-terraform-project

# 2. Create your own variables file (not committed, see .gitignore)
# Create terraform.tfvars with:
#   my_ip       = "YOUR_IP/32"        (get yours at whatismyip.com)
#   bucket_name = "yourname-tf-demo"  (must be globally unique)
#   aws_region  = "your-region"       (e.g. ap-south-1)

# 3. Initialize Terraform
terraform init

# 4. Preview the plan
terraform plan

# 5. Apply
terraform apply

# 6. When done, tear it down to avoid AWS charges
terraform destroy
```

## What I learned building this

- How Terraform's plan/apply/destroy cycle maps to real AWS resources
- Why the AWS Free Tier only covers `t3.micro` (not `t2.micro`) on newer accounts
- S3 bucket names must be globally unique and lowercase
- Why `terraform.tfvars` and `.tfstate` files should never be committed —
  they can contain sensitive data and machine-specific state
- How to scope an IAM role to least-privilege instead of broad/admin access

## Notes

- Built to stay within AWS Free Tier limits (`t3.micro`), but always run
  `terraform destroy` when not actively using it.
- SSH is restricted to a single IP (`var.my_ip`) rather than open to the
  world — an intentional security choice.
