#!/bin/sh
# This bash/shell script creates a snapshot of all instances on Vultr and deletes snapshots that exceed a specified limit.
# This updated script incorporates the following improvements so it can be run as a cronjob in a more unattended manner:
#
# 1. Uses absolute paths for all files and executables.
# 2. Implements proper logging to a log file.
# 3. Adds error handling with a custom function.
# 4. Includes a lock file mechanism to prevent multiple instances from running simultaneously.
# 5. Removes any interactive elements or prompts.
# 6. Uses a cleanup function with a trap to ensure the lock file is always removed.
#
# To use this script as a daily cronjob, you can add the following line to your crontab:
#
# 0 1 * * * /path/to/vultr-multi-instance-snapshots-script-w-limits.sh >> /path/to/vultr_snapshot.log 2>&1
#
# This will run the script daily at 1:00 AM and append both standard output and error messages to the log file.

set -e

# Use absolute paths
PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
INSTANCE_LIMITS_FILE="${SCRIPT_DIR}/instance_limits.conf"
LOG_FILE="${SCRIPT_DIR}/vultr_snapshot.log"
LOCK_FILE="/tmp/vultr_snapshot.lock"

# Logging function
log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# This function will check the number of lines in the log file. If it exceeds 500 lines, it will keep only the last 500 entries and update the log file. This ensures that the log file doesn't grow indefinitely over time while still maintaining a useful history of recent operations.

clear_log() {
    local log_lines=$(wc -l < "$LOG_FILE")
    if [ "$log_lines" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log file cleared, keeping last 500 entries"
    fi
}

# Error handling function
handle_error() {
    log "ERROR: $1"
    # Add email notification here if desired
    # mail -s "Vultr Snapshot Script Error" admin@example.com <<< "Error: $1"
    exit 1
}

# Check for lock file
if [ -f "$LOCK_FILE" ]; then
    handle_error "Script is already running. Exiting."
fi

# Create lock file
touch "$LOCK_FILE"

# Clear the log file
clear_log

# Cleanup function
cleanup() {
    rm -f "$LOCK_FILE"
}

# Set trap for cleanup
trap cleanup EXIT

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
else
    handle_error ".env file not found at $ENV_FILE"
fi

# Check for required commands
for cmd in curl jq gdate; do
    if ! command -v $cmd >/dev/null 2>&1; then
        handle_error "$cmd is required but not installed."
    fi
done

# Load configuration
VULTR_API_KEY=${VULTR_API_KEY:?"VULTR_API_KEY must be set"}
DEFAULT_SNAPSHOT_LIMIT=${VULTR_DEFAULT_SNAPSHOT_LIMIT:-4}

CURRENT_DATE=$(gdate +"%Y-%m-%dT%H:%M:%S.%3N")

# Function to make API calls
vultr_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    local response
    response=$(curl -s -f -X "$method" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} \
        "https://api.vultr.com/v2/$endpoint")
    echo "$response"
}

# Get all instances
instances=$(vultr_api_call GET "instances")
instance_ids=$(echo "$instances" | jq -r '.instances[].id')

for INSTANCE_ID in $instance_ids; do
    log "Processing instance: $INSTANCE_ID"

    # Get instance details
    instance_details=$(vultr_api_call GET "instances/${INSTANCE_ID}")

    # Extract instance details using jq
    INSTANCE_PLAN=$(echo "$instance_details" | jq -r '.instance.plan')
    INSTANCE_REGION=$(echo "$instance_details" | jq -r '.instance.region')
    INSTANCE_TAG=$(echo "$instance_details" | jq -r '.instance.tags[0]')

    SNAPSHOT_DESCRIPTION="${INSTANCE_TAG}-${INSTANCE_PLAN}-${INSTANCE_REGION}_${CURRENT_DATE}"

    # Get snapshot limit for this instance
    SNAPSHOT_LIMIT=$(grep "^${INSTANCE_ID}:" "$INSTANCE_LIMITS_FILE" | cut -d':' -f2)
    SNAPSHOT_LIMIT=${SNAPSHOT_LIMIT:-$DEFAULT_SNAPSHOT_LIMIT}

    # Get snapshots for this instance
    snapshots=$(vultr_api_call GET "snapshots?instance_id=${INSTANCE_ID}")
    SNAPSHOT_COUNT=$(echo "$snapshots" | jq '.snapshots | length')
    OLDEST_SNAPSHOT_ID=$(echo "$snapshots" | jq -r '.snapshots | sort_by(.date_created) | .[0].id')

    log "Current snapshot count for instance $INSTANCE_ID: $SNAPSHOT_COUNT"
    log "Snapshot limit: $SNAPSHOT_LIMIT"

    # If the number of snapshots is greater than or equal to the limit, delete the oldest one
    if [ "$SNAPSHOT_COUNT" -ge "$SNAPSHOT_LIMIT" ]; then
        log "Deleting oldest snapshot: $OLDEST_SNAPSHOT_ID"
        delete_response=$(vultr_api_call DELETE "snapshots/${OLDEST_SNAPSHOT_ID}")
        if [ $? -ne 0 ]; then
            handle_error "Failed to delete snapshot for instance $INSTANCE_ID"
        fi
        log "Snapshot deleted successfully"
    fi

    # Create a new snapshot
    log "Creating new snapshot with description: $SNAPSHOT_DESCRIPTION"
    create_response=$(vultr_api_call POST "snapshots" \
        "{\"instance_id\":\"$INSTANCE_ID\",\"description\":\"$SNAPSHOT_DESCRIPTION\"}")
    if [ $? -ne 0 ]; then
        handle_error "Failed to create snapshot for instance $INSTANCE_ID"
    fi
    new_snapshot_id=$(echo "$create_response" | jq -r '.snapshot.id')
    log "New snapshot created successfully with ID: $new_snapshot_id"

    log "Finished processing instance: $INSTANCE_ID"
    log "-------------------------------------------"
done

log "All instances processed."
