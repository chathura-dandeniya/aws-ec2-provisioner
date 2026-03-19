#!/bin/bash
set -eu

KEY_DIR="$(pwd)"
KEY_FILE="$KEY_DIR/id_rsa"
USER_DATA_FILE="$KEY_DIR/user-data.sh"
trap 'rm -f "$USER_DATA_FILE"' EXIT

if command -v cygpath &>/dev/null; then
  USER_DATA_FILE_WIN="$(cygpath -w "$USER_DATA_FILE")"
  KEY_FILE_WIN="$(cygpath -w "$KEY_FILE")"
else
  USER_DATA_FILE_WIN="$USER_DATA_FILE"
  KEY_FILE_WIN="$KEY_FILE"
fi


# ─── colours ─────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'


# ─── output helpers ───────────────────────────────────────────────────────────
prompt() {
  local label="$1" default="$2" varname="$3"
  local input
  printf "${CYAN}${BOLD}  ➜  ${RESET}${BOLD}%s${RESET} ${YELLOW}[%s]${RESET}: " "$label" "$default"
  read input
  printf -v "$varname" '%s' "${input:-$default}"
}

validate_not_empty() {
  local value="$1" label="$2"
  if [ -z "$value" ]; then
    echo -e "${RED}  ✖  $label cannot be empty.${RESET}"
    return 1
  fi
}

step()    { echo -e "${CYAN}${BOLD}  ⟳  ${RESET}${BOLD}$*${RESET}"; }
success() { echo -e "${GREEN}  ✔  $*${RESET}"; }
error()   { echo -e "${RED}  ✖  ERROR: $*${RESET}"; }


# ─── validators ───────────────────────────────────────────────────────────────
VALID_INSTANCE_TYPES=(
  t2.nano t2.micro t2.small t2.medium t2.large t2.xlarge t2.2xlarge
  t3.nano t3.micro t3.small t3.medium t3.large t3.xlarge t3.2xlarge
  t3a.nano t3a.micro t3a.small t3a.medium t3a.large t3a.xlarge t3a.2xlarge
  m5.large m5.xlarge m5.2xlarge m5.4xlarge
  m6i.large m6i.xlarge m6i.2xlarge m6i.4xlarge
  c5.large c5.xlarge c5.2xlarge c5.4xlarge
  c6i.large c6i.xlarge c6i.2xlarge c6i.4xlarge
  r5.large r5.xlarge r5.2xlarge r5.4xlarge
)

validate_instance_type() {
  local itype="$1"
  for valid in "${VALID_INSTANCE_TYPES[@]}"; do
    [ "$itype" = "$valid" ] && return 0
  done
  echo -e "${RED}  ✖  '$itype' is not a recognised instance type.${RESET}"
  echo -e "${YELLOW}     Valid examples: t2.micro, t3.small, m5.large, c5.xlarge${RESET}"
  return 1
}

validate_region() {
  local region="$1"
  step "Validating region '$region'..."
  if aws ec2 describe-regions \
    --filters "Name=region-name,Values=$region" \
    --query 'Regions[0].RegionName' \
    --output text 2>/dev/null | grep -q "$region"; then
    return 0
  fi
  echo -e "${RED}  ✖  '$region' is not a valid or enabled AWS region.${RESET}"
  echo -e "${YELLOW}     Run 'aws ec2 describe-regions' to see available regions.${RESET}"
  return 1
}


# ─── default values ───────────────────────────────────────────────────────────
SG_NAME="${SG_NAME:-xfusion-ec2-sg}"
INSTANCE_NAME="${INSTANCE_NAME:-xfusion-ec2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
REGION="${REGION:-$(aws configure get region)}"


# ─── phase 1: interactive inputs ─────────────────────────────────────────────
collect_inputs() {
  echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════╗"
  echo -e "║       EC2 Instance Configuration     ║"
  echo -e "╚══════════════════════════════════════╝${RESET}\n"

  while true; do
    prompt "Instance name"       "$INSTANCE_NAME" INSTANCE_NAME
    validate_not_empty "$INSTANCE_NAME" "Instance name" || continue

    prompt "Instance type"       "$INSTANCE_TYPE" INSTANCE_TYPE
    validate_not_empty "$INSTANCE_TYPE" "Instance type" || continue
    validate_instance_type "$INSTANCE_TYPE" || continue

    prompt "Security group name" "$SG_NAME"       SG_NAME
    validate_not_empty "$SG_NAME" "Security group name" || continue

    prompt "AWS region"          "$REGION"        REGION
    validate_not_empty "$REGION" "AWS region" || continue
    validate_region "$REGION" || continue

    break
  done

  echo -e "\n${BOLD}  Review your configuration:${RESET}"
  echo -e "  ${CYAN}Instance name   :${RESET} $INSTANCE_NAME"
  echo -e "  ${CYAN}Instance type   :${RESET} $INSTANCE_TYPE"
  echo -e "  ${CYAN}Security group  :${RESET} $SG_NAME"
  echo -e "  ${CYAN}Region          :${RESET} $REGION"

  echo -e "\n${YELLOW}${BOLD}  Proceed? (y/N): ${RESET}\c"
  read CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}  Aborted.${RESET}"
    exit 0
  fi

  export AWS_DEFAULT_REGION="$REGION"
  echo -e "\n${GREEN}  ✔  Starting provisioning...${RESET}\n"
}


# ─── phase 2: auth check + instance summary ───────────────────────────────────
check_auth_and_summary() {
  step "Verifying AWS CLI authentication..."
  if ! aws sts get-caller-identity --output text &>/dev/null; then
    error "AWS CLI is not authenticated. Run 'aws configure' or check your credentials."
    exit 1
  fi
  success "AWS CLI authenticated."

  step "Checking current instance count in region $REGION..."
  local instance_summary
  instance_summary=$(aws ec2 describe-instances \
    --query 'Reservations[].Instances[].[State.Name]' \
    --output text)

  local total running stopped other
  total=$(echo "$instance_summary"   | grep -c '.'         || true)
  running=$(echo "$instance_summary" | grep -c '^running$' || true)
  stopped=$(echo "$instance_summary" | grep -c '^stopped$' || true)
  other=$(( total - running - stopped ))

  echo -e "  ${CYAN}Total instances :${RESET} $total"
  echo -e "  ${GREEN}Running         :${RESET} $running"
  echo -e "  ${YELLOW}Stopped         :${RESET} $stopped"
  [ "$other" -gt 0 ] && echo -e "  ${RED}Other states    :${RESET} $other"
}


# ─── phase 3: SSH key setup ───────────────────────────────────────────────────
setup_ssh_key() {
  step "Checking SSH key..."
  if [ ! -f "$KEY_FILE" ]; then
    ssh-keygen -t rsa -b 2048 -f "$KEY_FILE" -N ""
    chmod 600 "$KEY_FILE"
    success "SSH key generated."
  else
    chmod 600 "$KEY_FILE"
    success "SSH key already exists. Skipping key generation."
  fi

  step "Importing key pair to AWS..."
  if ! aws ec2 import-key-pair \
    --key-name "$INSTANCE_NAME-key" \
    --public-key-material "fileb://${KEY_FILE_WIN}.pub" 2>/dev/null; then
    step "Key pair already exists, re-importing..."
    aws ec2 delete-key-pair --key-name "$INSTANCE_NAME-key"
    aws ec2 import-key-pair \
      --key-name "$INSTANCE_NAME-key" \
      --public-key-material "fileb://${KEY_FILE_WIN}.pub"
  fi
  success "Key pair ready."
}


# ─── phase 4: networking + security group ─────────────────────────────────────
setup_networking() {
  step "Getting default VPC..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text)

  if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    error "No default VPC found in this region"
    exit 1
  fi
  success "VPC found: $VPC_ID"

  step "Getting subnet..."
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
    --query 'Subnets[0].SubnetId' \
    --output text)

  if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
    error "No public subnet found in VPC $VPC_ID"
    exit 1
  fi
  success "Subnet found: $SUBNET_ID"

  step "Getting current public IP..."
  MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
  success "Your public IP: $MY_IP"

  step "Checking security group..."
  SG_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

  if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    step "Creating security group..."
    SG_ID=$(aws ec2 create-security-group \
      --group-name "$SG_NAME" \
      --description "SSH access for $INSTANCE_NAME" \
      --vpc-id "$VPC_ID" \
      --query 'GroupId' \
      --output text)
    success "Security group created: $SG_ID"
  else
    success "Security group already exists: $SG_ID"
  fi

  step "Revoking existing SSH ingress rules..."
  local existing_cidrs
  existing_cidrs=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' \
    --output text)

  for CIDR in $existing_cidrs; do
    aws ec2 revoke-security-group-ingress \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port 22 \
      --cidr "$CIDR" 2>/dev/null || true
  done

  step "Authorizing SSH access from ${MY_IP}/32 ..."
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "${MY_IP}/32"
  success "SSH access rule applied."
}


# ─── phase 5: AMI + launch ────────────────────────────────────────────────────
launch_instance() {
  step "Getting latest Amazon Linux 2 AMI..."
  local ami_id
  ami_id=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
    --output text)
  success "AMI found: $ami_id"

  step "Creating user-data script..."
  cat > "$USER_DATA_FILE" <<EOF
#!/bin/bash
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config

systemctl restart sshd

EOF
  step "Using user-data file: $USER_DATA_FILE_WIN"

  step "Checking for existing instance..."
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,pending,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)

  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    step "Launching EC2 instance..."
    INSTANCE_ID=$(aws ec2 run-instances \
      --image-id "$ami_id" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$INSTANCE_NAME-key" \
      --network-interfaces "AssociatePublicIpAddress=true,DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID" \
      --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
      --user-data "file://$USER_DATA_FILE_WIN" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
      --query 'Instances[0].InstanceId' \
      --output text)
    success "Instance launched: $INSTANCE_ID"
  else
    success "Instance already exists: $INSTANCE_ID. Skipping launch."
  fi

  step "Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

  local public_ip
  public_ip=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  if [ -z "$public_ip" ] || [ "$public_ip" = "None" ]; then
    error "Could not retrieve public IP for instance $INSTANCE_ID"
    exit 1
  fi
  success "Instance is running. Public IP: $public_ip"

  step "Waiting for SSH to be ready..."
  local max_retries=20
  local count=0
  until bash -c "echo > /dev/tcp/$public_ip/22" 2>/dev/null; do
    count=$(( count + 1 ))
    if [ "$count" -ge "$max_retries" ]; then
      error "SSH did not become ready after $max_retries attempts"
      exit 1
    fi
    echo -e "${YELLOW}     SSH not ready yet, retrying in 10 seconds... ($count/$max_retries)${RESET}"
    sleep 10
  done

  echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════╗"
  echo -e "║         Instance is ready! 🎉        ║"
  echo -e "╚══════════════════════════════════════╝${RESET}"
  echo -e "  ${CYAN}Public IP   :${RESET} $public_ip"
  echo -e "  ${CYAN}SSH command :${RESET} ssh -i $KEY_FILE ec2-user@$public_ip\n"
}


# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  collect_inputs
  check_auth_and_summary
  setup_ssh_key
  setup_networking
  launch_instance
}

main
