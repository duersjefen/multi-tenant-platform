#!/bin/bash
# =============================================================================
# Notification Functions
# =============================================================================
# Send notifications about deployment status
# Source this file: source /deploy/lib/functions/notifications.sh
# =============================================================================

# =============================================================================
# send_notification
# Sends a notification via configured channels
# =============================================================================
send_notification() {
    local title="$1"
    local message="$2"
    local severity="${3:-info}"  # info, warning, critical

    # Timestamp
    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    local full_message="[$timestamp] [$severity] $title\n$message"

    # Log to file
    echo -e "$full_message" >> /var/log/deployments.log

    # Send to configured notification channels
    # Example: Slack
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        send_slack_notification "$title" "$message" "$severity"
    fi

    # Example: Email
    if [ -n "${ALERT_EMAIL:-}" ]; then
        send_email_notification "$title" "$message" "$severity"
    fi

    # Claude notifications (if available)
    if [ -f "/home/martijn/.claude-notifications/claude_notify" ]; then
        send_claude_notification "$title" "$message" "$severity"
    fi
}

# =============================================================================
# send_slack_notification
# Sends notification to Slack
# =============================================================================
send_slack_notification() {
    local title="$1"
    local message="$2"
    local severity="$3"

    local color="good"
    local emoji="✅"

    case "$severity" in
        warning)
            color="warning"
            emoji="⚠️"
            ;;
        critical)
            color="danger"
            emoji="🚨"
            ;;
    esac

    local payload=$(cat <<EOF
{
    "attachments": [
        {
            "color": "$color",
            "title": "$emoji $title",
            "text": "$message",
            "footer": "Multi-Tenant Platform",
            "ts": $(date +%s)
        }
    ]
}
EOF
)

    curl -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "${SLACK_WEBHOOK_URL}" \
        2>/dev/null || true
}

# =============================================================================
# send_email_notification
# Sends notification via email
# =============================================================================
send_email_notification() {
    local title="$1"
    local message="$2"
    local severity="$3"

    # This would use your configured SMTP settings
    # For now, just a placeholder
    echo "Email notification: $title - $message" >> /var/log/email-notifications.log
}

# =============================================================================
# send_claude_notification
# Sends notification using Claude notification system
# =============================================================================
send_claude_notification() {
    local title="$1"
    local message="$2"
    local severity="$3"

    local type="milestone"

    case "$severity" in
        warning)
            type="error"
            ;;
        critical)
            type="error"
            ;;
        info)
            type="task_complete"
            ;;
    esac

    /home/martijn/.claude-notifications/claude_notify "$title: $message" "$type" 2>/dev/null || true
}

# =============================================================================
# notify_deployment_start
# =============================================================================
notify_deployment_start() {
    local project_name="$1"
    local environment="$2"

    send_notification \
        "🚀 Deployment Started" \
        "Project: $project_name\nEnvironment: $environment\nStarted by: $(whoami)" \
        "info"
}

# =============================================================================
# notify_deployment_success
# =============================================================================
notify_deployment_success() {
    local project_name="$1"
    local environment="$2"
    local duration="$3"

    send_notification \
        "✅ Deployment Successful" \
        "Project: $project_name\nEnvironment: $environment\nDuration: ${duration}s" \
        "info"
}

# =============================================================================
# notify_deployment_failure
# =============================================================================
notify_deployment_failure() {
    local project_name="$1"
    local environment="$2"
    local error="$3"

    send_notification \
        "❌ Deployment Failed" \
        "Project: $project_name\nEnvironment: $environment\nError: $error" \
        "critical"
}

# =============================================================================
# notify_rollback
# =============================================================================
notify_rollback() {
    local project_name="$1"
    local environment="$2"
    local reason="$3"

    send_notification \
        "⚠️ Rollback Initiated" \
        "Project: $project_name\nEnvironment: $environment\nReason: $reason" \
        "warning"
}