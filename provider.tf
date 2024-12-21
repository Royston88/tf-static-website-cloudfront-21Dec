terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.82.2"
    }
  }
}

# For S3
provider "aws" {
  region = "ap-southeast-1"
}

# For CloudFront, ACM, and WAF
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}
