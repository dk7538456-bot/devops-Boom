variable "aws_region" {
  type = string
  default = "ap-south-1"
}
variable "project_name" {
  type = string
  default = "taskforge"
}
variable "container_port" {
  type = number
  default = 8000
}
variable "desired_count" {
  type = number
  default = 0
}
variable "cpu" {
  type = number
  default = 256
}
variable "memory" {
  type = number
  default = 512
}
variable "image_tag" {
  type = string
  default = "latest"
}
variable "github_repository" {
  description = "GitHub owner/repository allowed to assume the deploy role, e.g. octocat/taskforge"
  type = string
  default = ""
}
