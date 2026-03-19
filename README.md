# AWS EC2 Provisioner

A production-grade Bash script that automates end-to-end EC2 instance provisioning on AWS — from SSH key generation to a ready-to-connect instance — with a styled interactive CLI, input validation, and idempotent resource management.

---

## Features

- **Interactive CLI** — colour-coded prompts with defaults, empty-input guards, and a confirmation summary before any AWS calls are made
- **Instance type validation** — checks entered type against a curated list of common families (`t2`, `t3`, `t3a`, `m5`, `m6i`, `c5`, `c6i`, `r5`) before proceeding
- **Live region validation** — queries `aws ec2 describe-regions` to confirm the entered region is valid and opted-in for your account
- **AWS auth check** — verifies CLI credentials with `sts get-caller-identity` at the start of provisioning, failing fast with a clear message rather than mid-run
- **Regional instance summary** — displays a running count of instances by state (running / stopped / other) before any launch decision is made
- **Idempotent resource handling** — safely re-runs without creating duplicates; detects existing key pairs, security groups, and instances by name
- **Dynamic IP-scoped SSH access** — fetches your current public IP and locks port 22 to `/32` only, replacing stale rules on each run
- **IMDSv2 enforced** — launches instances with `HttpTokens=required` to prevent SSRF-based metadata attacks
- **SSH key permissions** — enforces `chmod 600` on `id_rsa` regardless of how the key was created, preventing silent SSH rejections
- **Cygwin/Windows compatible** — detects `cygpath` and adjusts file paths for AWS CLI on Windows environments
- **Clean exit handling** — `trap` ensures the temporary `user-data.sh` is always removed, even on failure

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  provision.sh                   │
│                                                 │
│  collect_inputs()        Interactive prompts,   │
│                          validation, confirm    │
│                                                 │
│  check_auth_and_summary() Auth check +          │
│                           instance count        │
│                                                 │
│  setup_ssh_key()         Generate / import      │
│                          RSA key pair           │
│                                                 │
│  setup_networking()      VPC → Subnet →         │
│                          Security Group → Rules │
│                                                 │
│  launch_instance()       AMI lookup → Launch    │
│                          → Wait → SSH ready     │
└─────────────────────────────────────────────────┘
         │
         ▼
   EC2 Instance (Amazon Linux 2, IMDSv2)
   Public IP + SSH access from your IP only
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| AWS CLI | v2+ | `aws --version` |
| Bash | 4.0+ | macOS users: `brew install bash` |
| `ssh-keygen` | any | Usually pre-installed |
| `curl` | any | Used for public IP lookup |
| AWS credentials | — | `aws configure` or env vars |

Your AWS IAM user/role needs the following permissions:

```
ec2:DescribeRegions
ec2:DescribeVpcs
ec2:DescribeSubnets
ec2:DescribeInstances
ec2:DescribeImages
ec2:DescribeSecurityGroups
ec2:CreateSecurityGroup
ec2:AuthorizeSecurityGroupIngress
ec2:RevokeSecurityGroupIngress
ec2:ImportKeyPair
ec2:DeleteKeyPair
ec2:RunInstances
ec2:DescribeInstanceStatus
sts:GetCallerIdentity
```

---

## Usage

```bash
# Clone the repo
git clone https://github.com/<your-username>/aws-ec2-provisioner.git
cd aws-ec2-provisioner

# Make the script executable
chmod +x provision.sh

# Run
./provision.sh
```

The script will prompt you interactively:

```
╔══════════════════════════════════════╗
║       EC2 Instance Configuration     ║
╚══════════════════════════════════════╝

  ➜  Instance name [xfusion-ec2]:
  ➜  Instance type [t2.micro]:
  ➜  Security group name [xfusion-ec2-sg]:
  ➜  AWS region [ap-southeast-2]:

  Review your configuration:
  Instance name   : xfusion-ec2
  Instance type   : t2.micro
  Security group  : xfusion-ec2-sg
  Region          : ap-southeast-2

  Proceed? (y/N):
```

You can also pre-set values via environment variables to skip individual prompts:

```bash
INSTANCE_NAME=my-server INSTANCE_TYPE=t3.small ./provision.sh
```

---

## What Gets Created

| Resource | Details |
|---|---|
| SSH key pair | `id_rsa` / `id_rsa.pub` in working directory (`chmod 600` enforced) |
| AWS key pair | `<instance-name>-key` imported to EC2 |
| Security group | Port 22 open to your current public IP only |
| EC2 instance | Latest Amazon Linux 2 HVM x86_64, IMDSv2 required |

On completion:

```
╔══════════════════════════════════════╗
║         Instance is ready! 🎉        ║
╚══════════════════════════════════════╝
  Public IP   : 13.54.xx.xx
  SSH command : ssh -i /path/to/id_rsa ec2-user@13.54.xx.xx
```

---

## Security Considerations

- SSH access is scoped to your current public IP (`/32`) — not `0.0.0.0/0`
- IMDSv2 is enforced at launch via `--metadata-options HttpTokens=required`
- Private key permissions are set to `600` automatically
- The `user-data.sh` bootstrap file is deleted on script exit via `trap`
- Credentials are never written to disk by this script

---

## Re-running the Script

The script is fully idempotent:

- If the SSH key already exists locally → skips generation, re-imports to AWS
- If the security group already exists → reuses it, refreshes SSH rules
- If an instance with the same name is already running or stopped → skips launch

---

## Project Structure

```
aws-ec2-provisioner/
├── provision.sh      # Main provisioning script
├── .gitignore        # Excludes keys and temp files
└── README.md
```

---

## Author

**Chathura Dandeniya** — AWS Solutions Architect Associate | CKA | Terraform Associate  
[LinkedIn](https://www.linkedin.com/in/chathura-dandeniya-7913b022b/) · [GitHub](https://github.com/chathura-dandeniya/aws-ec2-provisioner)
