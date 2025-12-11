#!/bin/bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ALARM_SUFFIX="-cloudwatch-alarm"
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:860265990835:Alternative-Monitoring-Setup-SNS-Topic}"
ALARM_THRESHOLD="${ALARM_THRESHOLD:-5}"
ALARM_PERIOD=60

# =====================================================================
# Logging
# =====================================================================

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# =====================================================================
# Helper Functions
# =====================================================================

extract_queue_name() {
    echo "$1" | awk -F'/' '{print $NF}'
}

is_dlq() {
    [[ "$1" =~ -dlq$ || "$1" =~ -dead-letter$ || "$1" =~ _dlq$ ]]
}

get_threshold() {
    if is_dlq "$1"; then echo "1"; else echo "$ALARM_THRESHOLD"; fi
}

# =====================================================================
# AWS Fetching
# =====================================================================

# get_sqs_queues() {
#     aws sqs list-queues \
#         --region "$AWS_REGION" \
#         --query 'QueueUrls' \
#         --output text 2>/dev/null
# }

# get_cloudwatch_alarms() {
#     aws cloudwatch describe-alarms \
#         --region "$AWS_REGION" \
#         --query "MetricAlarms[?contains(AlarmName,'${ALARM_SUFFIX}')].AlarmName" \
#         --output text 2>/dev/null
# }

# =====================================================================
# AWS Fetching (Patched)
# =====================================================================

get_sqs_queues() {
    local output
    if ! output=$(aws sqs list-queues \
        --region "$AWS_REGION" \
        --query 'QueueUrls' \
        --output text 2>/dev/null); then
        log "No SQS queues found or permission missing."
        output=""
    fi
    echo "$output"
}

get_cloudwatch_alarms() {
    local output
    if ! output=$(aws cloudwatch describe-alarms \
        --region "$AWS_REGION" \
        --query "MetricAlarms[?contains(AlarmName,'${ALARM_SUFFIX}')].AlarmName" \
        --output text 2>/dev/null); then
        log "No CloudWatch alarms found or permission missing."
        output=""
    fi
    echo "$output"
}


# =====================================================================
# Alarm Management
# =====================================================================

create_alarm() {
    local queue="$1"
    local alarm_name="${queue}${ALARM_SUFFIX}"
    local threshold
    threshold=$(get_threshold "$queue")

    log "Creating alarm: $alarm_name (threshold=$threshold)"

    aws cloudwatch put-metric-alarm \
        --region "$AWS_REGION" \
        --alarm-name "$alarm_name" \
        --alarm-description "Alarm for SQS queue $queue" \
        --namespace "AWS/SQS" \
        --metric-name "ApproximateNumberOfMessagesVisible" \
        --dimensions "Name=QueueName,Value=$queue" \
        --statistic Average \
        --period "$ALARM_PERIOD" \
        --evaluation-periods 1 \
        --threshold "$threshold" \
        --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --ok-actions "$SNS_TOPIC_ARN"

    log "Created alarm: $alarm_name"
}

delete_alarm() {
    local alarm="$1"
    log "Deleting alarm: $alarm"

    aws cloudwatch delete-alarms \
        --region "$AWS_REGION" \
        --alarm-names "$alarm"

    log "Deleted alarm: $alarm"
}

# =====================================================================
# Main Logic
# =====================================================================

main() {
    log "Fetching SQS queues..."
    local queues
    queues=$(get_sqs_queues)

    log "Fetching CloudWatch alarms..."
    local alarms
    alarms=$(get_cloudwatch_alarms)

    declare -A queue_map
    declare -A alarm_map

    for url in $queues; do
        q=$(extract_queue_name "$url")
        queue_map["$q"]=1
    done

    for alarm in $alarms; do
        alarm_map["$alarm"]=1
    done

    # ------------------------------------------
    # Create Missing Alarms
    # ------------------------------------------
    for q in "${!queue_map[@]}"; do
        expected_alarm="${q}${ALARM_SUFFIX}"

        if [[ -z "${alarm_map[$expected_alarm]:-}" ]]; then
            log "Missing alarm → Creating: $expected_alarm"
            create_alarm "$q"
        else
            log "Alarm exists for: $q"
        fi
    done

    # ------------------------------------------
    # Delete Orphan Alarms
    # ------------------------------------------
    for alarm in "${!alarm_map[@]}"; do
        queue="${alarm%$ALARM_SUFFIX}"

        if [[ -z "${queue_map[$queue]:-}" ]]; then
            log "Orphan alarm detected → Deleting: $alarm"
            delete_alarm "$alarm"
        fi
    done

    log "Completed reconciliation."
}

main
