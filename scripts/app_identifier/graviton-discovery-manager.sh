#!/bin/bash
# Graviton Fleet Discovery Management Script
set -e

# Config
STACK_NAME="graviton-fleet-discovery"
TEMPLATE_FILE="graviton-fleet-discovery.yaml"
LOG_LEVEL="INFO"

# Colors & Logging
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
log() { local level=$(echo "$1" | tr '[:lower:]' '[:upper:]'); echo -e "${2:-$G}[$level]$N $3" >&2; }
err() { log error "$R" "$1"; return 1; }
warn() { log warn "$Y" "$1"; }
info() { log info "$G" "$1"; }

# AWS Utilities
region() { aws configure get region 2>/dev/null || echo "us-east-1"; }
exists() { aws cloudformation describe-stacks --stack-name "$1" --region "${REGION:-$(region)}" >/dev/null 2>&1; }
output() { aws cloudformation describe-stacks --stack-name "$1" --region "${REGION:-$(region)}" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null; }

# Normalize AWS CLI text output (tabs/newlines) to a single space-separated list.
flatten_instance_id_list() {
    echo "$1" | tr '\t\n\r' '   ' | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# All SSM-managed instances with PingStatus=Online in region (paginates via CLI).
list_ssm_online_instance_ids() {
    local reg="$1"
    aws ssm describe-instance-information --region "$reg" \
        --filters "Key=PingStatus,Values=Online" \
        --query 'InstanceInformationList[].InstanceId' --output text 2>/dev/null
}

# Parse instance IDs from input (file or inline)
parse_instance_ids() {
    local input="$1" ids=""
    
    # Check if input is a file
    if [[ -f "$input" ]]; then
        ids=$(tr '\n' ' ' < "$input" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    else
        ids="$input"
    fi
    
    echo "$ids"
}

# Usage
usage() {
cat << EOF
Graviton Fleet Discovery Management

Usage: $(basename "$0") COMMAND [OPTIONS]

COMMANDS:
  deploy     Deploy infrastructure
  update     Update existing infrastructure
  execute    Execute discovery on targets  
  download   Download results
  delete     Delete infrastructure
  status     Show stack status
  discover   Complete automated workflow

OPTIONS:
  --all              All SSM-managed instances with PingStatus=Online in the region (not EC2 tags)
  --instance-id IDS  Target specific instances (space/newline separated or file path)
  --tag KEY=VALUE    Target by EC2 tag (Key=Value)
  --region REGION    AWS region
  --dry-run          Show commands only
  --help             Show help

Examples:
  $(basename "$0") discover --all --region us-west-2
  $(basename "$0") execute --tag Environment=Production
  $(basename "$0") execute --instance-id "i-123 i-456 i-789"
  $(basename "$0") execute --instance-id instances.txt
EOF
}

# Prompt for missing parameters
prompt() {
    # Prompt for region if needed for commands that require it
    if [[ "$1" =~ ^(deploy|update|delete|status|discover)$ && -z "$REGION" ]]; then
        local r=$(region)
        info "Current region: $r"
        read -p "Region (Enter for $r): " REGION
        REGION=${REGION:-$r}
    fi
    
    # Prompt for target type if needed for execute/discover commands
    if [[ "$1" =~ ^(execute|discover)$ && -z "$TARGET_TYPE" ]]; then
        info "Target: 1)All 2)Instance IDs 3)Tags"
        read -p "Choice (1-3): " c
        case $c in
            1) TARGET_TYPE="all" TARGET_VALUE="all" ;;
            2) read -p "Instance IDs: " TARGET_VALUE; TARGET_TYPE="instance-id" ;;
            3) read -p "Tag (Key=Value): " TARGET_VALUE; TARGET_TYPE="tag" ;;
            *) err "Invalid choice" ;;
        esac
    fi
}

# Upload script to S3
upload() {
    local bucket="$1" region="$2" file="app_identifier.sh"
    [[ ! -f "$file" ]] && err "Script not found: $file"
    
    info "Uploading $file to $bucket"
    aws s3 cp "$file" "s3://$bucket/scripts/$file" --region "$region" >/dev/null || err "Upload failed"
}

# Wait for stack with progress
wait_stack() {
    local name="$1" op="$2" region="$3"
    info "Waiting for stack $op..."
    
    aws cloudformation wait "stack-$op-complete" --stack-name "$name" --region "$region" &
    local pid=$!
    
    local dots=0 prev=""
    while kill -0 $pid 2>/dev/null; do
        local status=$(aws cloudformation describe-stacks --stack-name "$name" --region "$region" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "UNKNOWN")
        
        [[ "$status" != "$prev" ]] && {
            [[ -n "$prev" ]] && printf "\n"
            printf "${B}[INFO]$N Stack: $status"
            prev="$status"; dots=0
        } || {
            printf "."; ((dots++))
            [[ $dots -ge 10 ]] && { printf "\n${B}[INFO]$N Stack: $status"; dots=0; }
        }
        sleep 3
    done
    
    if wait $pid; then
        printf "\n"
        info "Stack $op completed!"
        return 0
    fi
    printf "\n"
    err "Stack $op failed!"
    return 1
}

# Stack operations (deploy/update)
stack_op() {
    local op="$1" name="$2" template="$3" dry="$4" region="$5"
    [[ ! -f "$template" ]] && { err "Template not found: $template"; return 1; }

    if [[ "$op" == "create" ]]; then
        if exists "$name"; then
            err "Stack exists. Use update."
            return 1
        fi
    else
        if ! exists "$name"; then
            err "Stack missing. Use deploy."
            return 1
        fi
    fi

    local cmd="aws cloudformation $op-stack --stack-name $name --template-body file://$template --capabilities CAPABILITY_NAMED_IAM --region $region"

    [[ "$dry" == "true" ]] && { warn "DRY RUN: $cmd"; return 0; }

    local action="deploy"
    [[ "$op" == "update" ]] && action="updat"
    info "${action}ing stack: $name"

    local cf_out cf_rc
    cf_out=$(eval "$cmd" 2>&1) && cf_rc=0 || cf_rc=$?
    if [[ $cf_rc -ne 0 ]]; then
        if [[ "$op" == "update" && "$cf_out" == *"No updates are to be performed"* ]]; then
            warn "CloudFormation template unchanged (no stack update). Uploading discovery script to the bucket anyway."
        else
            err "Stack $op failed: $cf_out"
            return 1
        fi
    else
        if ! wait_stack "$name" "$op" "$region"; then return 1; fi
    fi

    local bucket
    bucket=$(output "$name" "S3BucketName")
    [[ -n "$bucket" ]] && upload "$bucket" "$region" >/dev/null
    return 0
}

# Send SSM Run Command in chunks of 50 instance IDs (AWS limit). Prints one CommandId per line to stdout.
send_command_batches() {
    local doc="$1" reg="$2" level="$3" dry="$4" ids_flat="$5"
    local -a id_array=()
    read -ra id_array <<< "$ids_flat"
    [[ ${#id_array[@]} -eq 0 ]] && { err "No instance IDs to target"; return 1; }

    local batch_size=50 i=0 batch_num=0
    while (( i < ${#id_array[@]} )); do
        ((batch_num++))
        local batch=("${id_array[@]:i:batch_size}")
        local id_args=""
        for id in "${batch[@]}"; do id_args="$id_args \"$id\""; done
        local base="aws ssm send-command --region \"$reg\" --document-name \"$doc\" --instance-ids$id_args"
        [[ "$level" != "INFO" ]] && base="$base --parameters logLevel=$level"

        info "SSM batch $batch_num (${#batch[@]} instance(s), ${#id_array[@]} total)"
        if [[ "$dry" == "true" ]]; then
            warn "DRY RUN: $base"
        else
            local bid
            bid=$(eval "$base" --query 'Command.CommandId' --output text) || { err "SSM batch $batch_num failed"; return 1; }
            [[ -z "$bid" ]] && { err "SSM batch $batch_num returned empty CommandId"; return 1; }
            info "Command ID: $bid"
            echo "$bid"
        fi
        ((i += batch_size))
    done
    return 0
}

# Execute SSM command. For --all, stdout is one command ID per line (batched). Else one line.
execute() {
    local name="$1" type="$2" value="$3" level="$4" dry="$5"
    local reg="${6:-${REGION:-$(region)}}"

    if ! exists "$name"; then
        err "Stack missing. Deploy first."
        return 1
    fi

    local doc
    doc=$(output "$name" "SSMDocumentName")
    [[ -z "$doc" ]] && { err "SSM document not found"; return 1; }

    info "Target: $type=$value"

    case "$type" in
        "instance-id")
            local ids_flat
            ids_flat=$(flatten_instance_id_list "$value")
            [[ -z "$ids_flat" ]] && { err "No instance IDs provided"; return 1; }
            [[ "$dry" == "true" ]] && {
                warn "DRY RUN: send-command to ${ids_flat// /, }"
                return 0
            }
            info "Executing SSM command..."
            send_command_batches "$doc" "$reg" "$level" "$dry" "$ids_flat"
            ;;
        "tag")
            local targets=""
            IFS=',' read -ra pairs <<< "$value"
            for pair in "${pairs[@]}"; do
                IFS='=' read -ra parts <<< "$pair"
                [[ ${#parts[@]} -eq 2 ]] || { err "Invalid tag: $pair"; return 1; }
                targets="$targets \"Key=tag:${parts[0]},Values=${parts[1]}\""
            done
            local cmd="aws ssm send-command --region \"$reg\" --document-name \"$doc\" --targets$targets"
            [[ "$level" != "INFO" ]] && cmd="$cmd --parameters logLevel=$level"
            [[ "$dry" == "true" ]] && { warn "DRY RUN: $cmd"; return 0; }
            info "Executing SSM command..."
            local id
            id=$(eval "$cmd" --query 'Command.CommandId' --output text) || { err "SSM execution failed"; return 1; }
            [[ -z "$id" ]] && { err "SSM returned empty CommandId"; return 1; }
            info "Command ID: $id"
            echo "$id"
            ;;
        "all")
            local ids_raw ids_flat n
            ids_raw=$(list_ssm_online_instance_ids "$reg")
            ids_flat=$(flatten_instance_id_list "$ids_raw")
            n=0
            [[ -n "$ids_flat" ]] && read -ra _cnt <<< "$ids_flat" && n=${#_cnt[@]}
            info "SSM Online instances in $reg: $n"
            [[ "$n" -eq 0 ]] && {
                err "No SSM Online instances in $reg. Ensure agents are registered and PingStatus=Online."
                return 1
            }
            [[ "$dry" == "true" ]] && {
                warn "DRY RUN: would send-command to $n instance(s) in batch(es) of up to 50"
                return 0
            }
            info "Executing discovery..."
            send_command_batches "$doc" "$reg" "$level" "$dry" "$ids_flat"
            ;;
        *)
            err "Invalid target: $type"
            return 1
            ;;
    esac
}

# Wait for SSM completion
wait_ssm() {
    local id="$1" timeout="${2:-30}"
    local reg="${3:-${REGION:-$(region)}}"
    info "Waiting for SSM completion (${timeout}m timeout)..."
    
    local start=$(date +%s) limit=$((timeout * 60))
    
    while true; do
        local status=$(aws ssm list-commands --region "$reg" --command-id "$id" --query 'Commands[0].Status' --output text 2>/dev/null || echo "Unknown")
        local targets=$(aws ssm list-commands --region "$reg" --command-id "$id" --query 'Commands[0].TargetCount' --output text 2>/dev/null || echo "0")
        local done=$(aws ssm list-commands --region "$reg" --command-id "$id" --query 'Commands[0].CompletedCount' --output text 2>/dev/null || echo "0")
        local errors=$(aws ssm list-commands --region "$reg" --command-id "$id" --query 'Commands[0].ErrorCount' --output text 2>/dev/null || echo "0")
        
        info "Status: $status | Targets: $targets | Done: $done | Errors: $errors"
        
        case "$status" in
            "Success")
                if [[ "${targets:-0}" == "0" ]]; then
                    err "SSM reported Success but TargetCount=0 (no instances ran the document). Use fixed --all (SSM Online list) or fix --tag/--instance-id."
                    return 1
                fi
                info "SSM completed successfully ($targets target(s))!"
                return 0
                ;;
            "Failed"|"Cancelled") err "SSM $status!"; return 1 ;;
        esac
        
        if [[ $(( $(date +%s) - start )) -ge $limit ]]; then
            err "SSM timeout after ${timeout}m"
            return 1
        fi
        sleep 10
    done
}

# Download results
download() {
    local name="$1"
    ! exists "$name" && err "Stack missing"
    
    local bucket=$(output "$name" "S3BucketName")
    [[ -z "$bucket" ]] && err "Bucket not found"
    
    local dir="graviton-discovery-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    
    info "Downloading from $bucket to $dir"
    
    # List all SBOM files and download them to the same directory (flatten structure)
    local files=$(aws s3 ls "s3://$bucket/graviton-discovery/" --recursive | grep -E "\.sbom\.json$|sbom_container_.*\.json$" | awk '{print $4}')
    
    if [[ -z "$files" ]]; then
        warn "No SBOM files found in S3 bucket"
        return
    fi
    
    local count=0
    while IFS= read -r file; do
        [[ -n "$file" ]] && {
            local filename=$(basename "$file")
            aws s3 cp "s3://$bucket/$file" "$dir/$filename" || warn "Failed to download $file"
            ((count++))
        }
    done <<< "$files"
    
    info "Downloaded $count SBOM files to: $dir"
}

# Delete stack with cleanup
delete() {
    local name="$1" dry="$2" region="$3"
    ! exists "$name" && err "Stack missing"
    
    local bucket=$(output "$name" "S3BucketName")
    
    [[ "$dry" == "true" ]] && { warn "DRY RUN: Would delete $name and empty $bucket"; return; }
    
    warn "Will delete stack and empty bucket: $bucket"
    read -p "Continue? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Cancelled"; return; }
    
    # Empty bucket
    if [[ -n "$bucket" ]] && aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
        local count=$(aws s3api list-objects-v2 --bucket "$bucket" --region "$region" --query 'KeyCount' --output text 2>/dev/null || echo "0")
        [[ "$count" != "0" ]] && {
            info "Emptying bucket ($count objects)..."
            aws s3 rm "s3://$bucket" --recursive --region "$region" || warn "Bucket cleanup failed"
        }
    fi
    
    info "Deleting stack: $name"
    aws cloudformation delete-stack --stack-name "$name" --region "$region" || err "Delete failed"
    wait_stack "$name" "delete" "$region"
}

# Show status
status() {
    local name="$1" region="$2"
    aws cloudformation describe-stacks --stack-name "$name" --region "$region" >/dev/null 2>&1 || err "Stack missing in $region"
    
    info "Stack Status:"
    aws cloudformation describe-stacks --stack-name "$name" --region "$region" \
        --query 'Stacks[0].[StackName,StackStatus,CreationTime]' --output table
    
    info "Outputs:"
    aws cloudformation describe-stacks --stack-name "$name" --region "$region" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
}

# Complete discovery workflow
discover() {
    local name="$1" template="$2" type="$3" value="$4" level="$5" dry="$6" region="$7"
    
    info "Automated Graviton Fleet Discovery Workflow"
    info "This will:"
    info "  1. Deploy AWS infrastructure (CloudFormation + S3)"
    info "  2. Execute discovery on target instances"
    info "  3. Download SBOM files locally"
    info "  4. Clean up AWS resources"
    echo
    
    [[ "$dry" != "true" ]] && {
        read -p "Continue? (y/N): " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Cancelled"; return; }
    }
    
    # Deploy (create if missing, else update — avoids AlreadyExists on re-runs)
    info "Step 1/4: Deploying infrastructure..."
    if exists "$name"; then
        info "Stack $name already exists; updating template and uploading script..."
        stack_op "update" "$name" "$template" "$dry" "$region" || { err "Update failed"; return 1; }
    else
        stack_op "create" "$name" "$template" "$dry" "$region" || { err "Deploy failed"; return 1; }
    fi

    [[ "$dry" == "true" ]] && { info "DRY RUN: Would continue workflow"; return; }

    # Execute (stdout: one command ID per batch for --all / many instance-ids)
    info "Step 2/4: Executing discovery..."
    local cmd_out
    if ! cmd_out=$(execute "$name" "$type" "$value" "$level" "$dry" "$region"); then
        err "Execute failed"
        return 1
    fi
    if [[ -z "$(echo "$cmd_out" | tr -d '[:space:]')" ]]; then
        err "Execute failed (no command ID returned)"
        return 1
    fi
    local cid
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        wait_ssm "$cid" 30 "$region" || { err "SSM failed for command $cid"; return 1; }
    done <<< "$cmd_out"
    
    # Download
    info "Step 3/4: Downloading results..."
    download "$name" || warn "Download failed - retrieve manually"
    
    # Cleanup
    info "Step 4/4: Cleaning up..."
    local bucket=$(output "$name" "S3BucketName")
    
    # Auto cleanup without prompts
    [[ -n "$bucket" ]] && aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1 && {
        local count=$(aws s3api list-objects-v2 --bucket "$bucket" --region "$region" --query 'KeyCount' --output text 2>/dev/null || echo "0")
        [[ "$count" != "0" ]] && {
            info "Emptying bucket ($count objects)..."
            aws s3 rm "s3://$bucket" --recursive --region "$region" >/dev/null || warn "Cleanup failed"
        }
    }
    
    info "Deleting stack..."
    aws cloudformation delete-stack --stack-name "$name" --region "$region" >/dev/null || warn "Delete failed"
    wait_stack "$name" "delete" "$region" || warn "Delete incomplete"
    
    info "Workflow completed!"
}

# Parse arguments
CMD="" TARGET_TYPE="" TARGET_VALUE="" DRY="false" REGION=""

[[ $# -eq 0 ]] && { usage; exit 1; }

# Handle help options first
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
fi

CMD="$1"; shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --all) TARGET_TYPE="all" TARGET_VALUE="all"; shift ;;
        --instance-id) 
            TARGET_TYPE="instance-id"
            shift
            # Collect all instance IDs until next option or end
            ids=""
            while [[ $# -gt 0 && "$1" != --* ]]; do
                ids="$ids $1"
                shift
            done
            TARGET_VALUE=$(parse_instance_ids "$ids")
            ;;
        --tag) TARGET_TYPE="tag" TARGET_VALUE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --dry-run) DRY="true"; shift ;;
        --help) usage; exit 0 ;;
        *) log error "$R" "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Check AWS CLI
command -v aws >/dev/null || err "AWS CLI not found"

# Main
info "Graviton Fleet Discovery Manager"
prompt "$CMD"
[[ -n "$REGION" ]] && export AWS_DEFAULT_REGION="$REGION"

case "$CMD" in
    deploy)
        if exists "$STACK_NAME"; then
            info "Stack exists; updating..."
            stack_op "update" "$STACK_NAME" "$TEMPLATE_FILE" "$DRY" "$REGION"
        else
            stack_op "create" "$STACK_NAME" "$TEMPLATE_FILE" "$DRY" "$REGION"
        fi
        ;;
    update) stack_op "update" "$STACK_NAME" "$TEMPLATE_FILE" "$DRY" "$REGION" ;;
    execute) execute "$STACK_NAME" "$TARGET_TYPE" "$TARGET_VALUE" "$LOG_LEVEL" "$DRY" "$REGION" ;;
    download) download "$STACK_NAME" ;;
    delete) delete "$STACK_NAME" "$DRY" "$REGION" ;;
    status) status "$STACK_NAME" "$REGION" ;;
    discover) discover "$STACK_NAME" "$TEMPLATE_FILE" "$TARGET_TYPE" "$TARGET_VALUE" "$LOG_LEVEL" "$DRY" "$REGION" ;;
    *) log error "$R" "Unknown command: $CMD"; usage; exit 1 ;;
esac