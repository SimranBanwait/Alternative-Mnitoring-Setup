#!/bin/bash

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# ============================================================================
# SQS CloudWatch Alarm Reconciliation Script
# ============================================================================
# This script reconciles CloudWatch alarms with existing SQS queues:
# - Creates alarms for queues that don't have them
# - Deletes alarms for queues that no longer exist
# ============================================================================

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
ALARM_THRESHOLD="${ALARM_THRESHOLD:-5}"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:860265990835:test-topic}"
ALARM_PERIOD="${ALARM_PERIOD:-60}"  # 1 minute

# Counters for summary
CREATED_COUNT=0
DELETED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

# Arrays to store details
declare -a CREATED_ALARMS
declare -a DELETED_ALARMS
declare -a FAILED_OPERATIONS

# ============================================================================
# Logging Functions
# ============================================================================

# log_info() {
#     echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
# }

# log_error() {
#     echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
# }

# log_success() {
#     echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*"
# }

# log_warning() {
#     echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $*"
# }

# ============================================================================
# Logging Functions (UPDATED)
# ============================================================================

log_info() {
    # Changed echo to 'echo ... >&2'
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
    # This was already correct, but explicitly showing the change
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_success() {
    # Changed echo to 'echo ... >&2'
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_warning() {
    # Changed echo to 'echo ... >&2'
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# ============================================================================
# Helper Functions
# ============================================================================

# Extract queue name from queue URL
# Example: https://sqs.us-east-1.amazonaws.com/123456789/my-queue -> my-queue
extract_queue_name() {
    local queue_url=$1
    echo "$queue_url" | awk -F'/' '{print $NF}'
}

# Detect if queue is a Dead Letter Queue
is_dlq() {
    local queue_name=$1
    if [[ "$queue_name" =~ -dlq$ ]] || [[ "$queue_name" =~ -dead-letter$ ]] || [[ "$queue_name" =~ _dlq$ ]]; then
        return 0  # True - it is a DLQ
    else
        return 1  # False - it's not a DLQ
    fi
}

# Get appropriate threshold based on queue type
get_threshold_for_queue() {
    local queue_name=$1
    
    if is_dlq "$queue_name"; then
        echo "1"  # DLQ: Alert on ANY message
    else
        echo "$ALARM_THRESHOLD"  # Normal queue: Use configured threshold
    fi
}

# ============================================================================
# AWS API Functions
# ============================================================================

# Get all SQS queue URLs
get_all_queue_urls() {
    log_info "Fetching all SQS queues in region: $AWS_REGION"
    
    local queue_urls
    queue_urls=$(aws sqs list-queues \
        --region "$AWS_REGION" \
        --query 'QueueUrls' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$queue_urls" ]; then
        log_warning "No SQS queues found in region $AWS_REGION"
        return 1
    fi
    
    local queue_count=$(echo "$queue_urls" | wc -w)
    log_success "Found $queue_count SQS queue(s)"
    
    echo "$queue_urls"
}

# Get all CloudWatch alarms for SQS (with our naming convention)
get_all_sqs_alarms() {
    log_info "Fetching all SQS CloudWatch alarms..."
    
    local alarm_names
    alarm_names=$(aws cloudwatch describe-alarms \
        --alarm-name-prefix "SQS-HighMessageCount-" \
        --region "$AWS_REGION" \
        --query 'MetricAlarms[].AlarmName' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$alarm_names" ]; then
        log_info "No existing SQS alarms found"
        return 1
    fi
    
    local alarm_count=$(echo "$alarm_names" | wc -w)
    log_success "Found $alarm_count existing alarm(s)"
    
    echo "$alarm_names"
}

# ============================================================================
# Alarm Management Functions
# ============================================================================

# Create CloudWatch alarm for a queue
create_alarm_for_queue() {
    local queue_name=$1
    local threshold=$(get_threshold_for_queue "$queue_name")
    local alarm_name="SQS-HighMessageCount-${queue_name}"
    
    log_info "Creating alarm: $alarm_name (threshold: $threshold)"
    
    # Build alarm description based on queue type
    local alarm_description
    if is_dlq "$queue_name"; then
        alarm_description="🚨 CRITICAL: Messages detected in Dead Letter Queue: $queue_name"
    else
        alarm_description="Alert when SQS queue $queue_name has $threshold or more messages available"
    fi
    
    # Create the alarm
    if aws cloudwatch put-metric-alarm \
        --alarm-name "$alarm_name" \
        --alarm-description "$alarm_description" \
        --namespace "AWS/SQS" \
        --metric-name "ApproximateNumberOfMessagesVisible" \
        --dimensions "Name=QueueName,Value=$queue_name" \
        --statistic "Average" \
        --period "$ALARM_PERIOD" \
        --evaluation-periods 1 \
        --threshold "$threshold" \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --treat-missing-data "notBreaching" \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --ok-actions "$SNS_TOPIC_ARN" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        
        log_success "✓ Created alarm: $alarm_name"
        CREATED_ALARMS+=("$alarm_name")
        ((CREATED_COUNT++))
        
        # Tag the alarm for better management (optional, ignore failures)
        aws cloudwatch tag-resource \
            --resource-arn "arn:aws:cloudwatch:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):alarm:${alarm_name}" \
            --tags "Key=ManagedBy,Value=Automation" "Key=QueueName,Value=${queue_name}" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        
        return 0
    else
        log_error "✗ Failed to create alarm: $alarm_name"
        FAILED_OPERATIONS+=("CREATE: $alarm_name")
        ((ERROR_COUNT++))
        return 1
    fi
}

# Delete CloudWatch alarm
delete_alarm() {
    local alarm_name=$1
    
    log_info "Deleting orphaned alarm: $alarm_name"
    
    if aws cloudwatch delete-alarms \
        --alarm-names "$alarm_name" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        
        log_success "✓ Deleted alarm: $alarm_name"
        DELETED_ALARMS+=("$alarm_name")
        ((DELETED_COUNT++))
        return 0
    else
        log_error "✗ Failed to delete alarm: $alarm_name"
        FAILED_OPERATIONS+=("DELETE: $alarm_name")
        ((ERROR_COUNT++))
        return 1
    fi
}

# ============================================================================
# Reconciliation Logic
# ============================================================================

reconcile_alarms() {
    log_info "Starting reconciliation process..."
    
    # Get all queue URLs
    local queue_urls
    if ! queue_urls=$(get_all_queue_urls); then
        log_warning "No queues to process, exiting"
        return 0
    fi
    
    # Build associative array of queue names
    declare -A queue_map
    for url in $queue_urls; do
        local name=$(extract_queue_name "$url")
        queue_map[$name]=1
        log_info "  → Queue: $name"
    done
    
    # Get all existing alarms
    local existing_alarms
    existing_alarms=$(get_all_sqs_alarms) || existing_alarms=""
    
    echo ""
    log_info "========================================"
    log_info "Phase 1: Creating Missing Alarms"
    log_info "========================================"
    
    # Check each queue for missing alarm
    for queue_name in "${!queue_map[@]}"; do
        local expected_alarm="SQS-HighMessageCount-${queue_name}"
        
        if echo "$existing_alarms" | grep -qw "$expected_alarm"; then
            log_info "Alarm already exists for: $queue_name"
            ((SKIPPED_COUNT++))
        else
            log_warning "Missing alarm for: $queue_name"
            create_alarm_for_queue "$queue_name"
        fi
    done
    
    echo ""
    log_info "========================================"
    log_info "Phase 2: Deleting Orphaned Alarms"
    log_info "========================================"
    
    # Check for orphaned alarms (alarms without corresponding queues)
    if [ -n "$existing_alarms" ]; then
        for alarm_name in $existing_alarms; do
            # Extract queue name from alarm name
            # SQS-HighMessageCount-my-queue -> my-queue
            local queue_name=${alarm_name#SQS-HighMessageCount-}
            
            if [ -z "${queue_map[$queue_name]:-}" ]; then
                log_warning "Orphaned alarm found: $alarm_name (queue no longer exists)"
                delete_alarm "$alarm_name"
            else
                log_info "Alarm is valid: $alarm_name"
            fi
        done
    else
        log_info "No existing alarms to check for orphans"
    fi
}

# ============================================================================
# Summary and Notifications
# ============================================================================

send_summary_notification() {
    log_info "Preparing summary notification..."
    
    local summary_message
    summary_message="SQS CloudWatch Alarm Reconciliation Complete

========================================
SUMMARY
========================================
✓ Alarms Created:  $CREATED_COUNT
✗ Alarms Deleted:  $DELETED_COUNT
→ Alarms Unchanged: $SKIPPED_COUNT
⚠ Errors:          $ERROR_COUNT

Region: $AWS_REGION
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
"

    # Add details of created alarms
    if [ $CREATED_COUNT -gt 0 ]; then
        summary_message+="
Created Alarms:
"
        for alarm in "${CREATED_ALARMS[@]}"; do
            summary_message+="  • $alarm
"
        done
    fi
    
    # Add details of deleted alarms
    if [ $DELETED_COUNT -gt 0 ]; then
        summary_message+="
Deleted Alarms:
"
        for alarm in "${DELETED_ALARMS[@]}"; do
            summary_message+="  • $alarm
"
        done
    fi
    
    # Add errors if any
    if [ $ERROR_COUNT -gt 0 ]; then
        summary_message+="
Failed Operations:
"
        for op in "${FAILED_OPERATIONS[@]}"; do
            summary_message+="  • $op
"
        done
    fi
    
    # Send to SNS
    if aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "SQS Alarm Reconciliation: $CREATED_COUNT created, $DELETED_COUNT deleted" \
        --message "$summary_message" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_success "Summary notification sent successfully"
    else
        log_warning "Failed to send summary notification (non-critical)"
    fi
    
    # Print summary to console
    echo ""
    echo "========================================"
    echo "$summary_message"
    echo "========================================"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo "========================================"
    echo "SQS CloudWatch Alarm Reconciliation"
    echo "========================================"
    echo ""
    
    log_info "Configuration:"
    log_info "  Region:          $AWS_REGION"
    log_info "  Alarm Threshold: $ALARM_THRESHOLD messages"
    log_info "  Alarm Period:    $ALARM_PERIOD seconds"
    log_info "  SNS Topic:       $SNS_TOPIC_ARN"
    echo ""
    
    # Run reconciliation
    reconcile_alarms
    
    # Send summary
    send_summary_notification
    
    # Exit with appropriate code
    if [ $ERROR_COUNT -gt 0 ]; then
        log_warning "Reconciliation completed with $ERROR_COUNT error(s)"
        exit 1
    else
        log_success "Reconciliation completed successfully!"
        exit 0
    fi
}

# Run main function
main