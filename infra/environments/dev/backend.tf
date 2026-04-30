terraform {
  backend "s3" {
    bucket = "wiz-exercise-tfstate-12345"
    key    = "wiz-exercise/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "wiz-exercise-tflock"
  }
}