# 01 — Infrastructure Provisioning Runbook

## What is Terraform?
Terraform is an Infrastructure as Code (IaC) tool that lets you define
and provision cloud infrastructure using configuration files instead of
clicking through the AWS console manually.

## Why do we use Terraform here?
- Reproducible — same infrastructure every time
- Version controlled — infrastructure changes tracked in Git
- Automated — no manual clicking in AWS console

---

## Prerequisites

- AWS CLI installed and configured
  ```bash
  aws --version
  aws configure
  ```

- Terraform installed
  ```bash
  terraform -version
  ```

- SSH key pair exists
  ```bash
  ls ~/.ssh/id_rsa ~/.ssh/id_rsa.pub
  ```

  If not, generate one:
  ```bash
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
  ```

---

## Execution Order

### Step 1 — Clone the repository
> Run on: **Local Machine**

```bash
git clone https://github.com/iksanh/aws-k8s-lab.git
cd aws-k8s-lab
```

### Step 2 — Configure variables
> Run on: **Local Machine**

Copy the example vars file and fill in your values:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
cluster_name          = "k8s-lab"
region                = "us-east-1"
public_key_path       = "~/.ssh/id_rsa.pub"
bastion_instance_type = "t3.micro"
```

> Never commit `terraform.tfvars` to Git — it may contain sensitive values.
> Make sure it is listed in `.gitignore`.

### Step 3 — Initialize Terraform
> Run on: **Local Machine**

Downloads required providers (AWS, etc.) and initializes the backend:
```bash
terraform init
```

Expected output:
```
Initializing the backend...
Initializing provider plugins...
- Installing hashicorp/aws v5.x.x...

Terraform has been successfully initialized!
```

### Step 4 — Validate configuration
> Run on: **Local Machine**

Check for syntax errors before applying:
```bash
terraform validate
```

Expected output:
```
Success! The configuration is valid.
```

### Step 5 — Preview changes
> Run on: **Local Machine**

Always run plan before apply to review what will be created:
```bash
terraform plan
```

Review the output carefully:
```
Plan: 25 to add, 0 to change, 0 to destroy.
```

### Step 6 — Apply infrastructure
> Run on: **Local Machine**

```bash
terraform apply
```

Type `yes` when prompted. This will take approximately 3-5 minutes.

Expected output:
```
Apply complete! Resources: 25 added, 0 changed, 0 destroyed.

Outputs:

bastion_public_ip = "44.216.65.182"
nlb_dns           = "k8s-lab-cp-nlb-xxx.elb.us-east-1.amazonaws.com"
alb_dns           = "k8s-lab-alb-xxx.us-east-1.elb.amazonaws.com"
...
```

### Step 7 — Generate Ansible inventory
> Run on: **Local Machine**

Parse Terraform output and generate `ansible/inventory/hosts.ini`:
```bash
bash scripts/generate-inventory.sh
```

Verify the inventory file:
```bash
cat ansible/inventory/hosts.ini
```

Expected output:
```ini
[bastion]
bastion-host ansible_host=44.216.65.182 ansible_user=ubuntu ...

[control_plane]
cp-1 ansible_host=10.0.10.x ansible_user=ubuntu ...

[workers]
worker-1 ansible_host=10.0.20.x ansible_user=ubuntu ...
worker-2 ansible_host=10.0.21.x ansible_user=ubuntu ...
```

### Step 8 — Verify SSH connectivity
> Run on: **Local Machine**

```bash
ansible all -i ansible/inventory/hosts.ini -m ping
```

Expected output:
```
bastion-host | SUCCESS
cp-1         | SUCCESS
worker-1     | SUCCESS
worker-2     | SUCCESS
```

---

## Destroying Infrastructure

> This will destroy ALL resources including EC2, RDS, VPC.
> Make sure you have backed up anything important.

```bash
terraform destroy
```

---

## Troubleshooting

### AWS credentials not configured
```bash
aws configure
# Enter: AWS Access Key ID, Secret Access Key, region (us-east-1), output (json)
```

### SSH key not found
```bash
# Generate new key pair
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa

# Update terraform.tfvars
public_key_path = "~/.ssh/id_rsa.pub"
```

### Terraform state conflict
```bash
# If state is locked
terraform force-unlock <LOCK_ID>
```

### Resource already exists error
```bash
# Import existing resource into state
terraform import aws_instance.bastion <instance-id>
```