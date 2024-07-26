#!/bin/sh
set -e
# This version of the script retrieves all Vultr instances associated with your account and allows you to set individual limits for specific instances while using a default limit for others. It's a flexible solution that keeps your main script clean while allowing for easy configuration updates. By using this method, you keep your sensitive information separate from the script, making it easier to manage and more secure. Remember to add .env to your .gitignore file if you're using version control to prevent accidentally committing sensitive information.

# Adjust the path below per your system.
PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin"

# Function to display usage information
usage() {
    echo "Usage: $0 [-h] [-d]"
    echo "  -h  Display this help message"
    echo "  -d  Dry run (show actions without performing them)"
    exit 1
}

# Parse command line options
dry_run=false
while getopts "hd" opt; do
    case ${opt} in
        h ) usage ;;
        d ) dry_run=true ;;
        \? ) usage ;;
    esac
done

# Check for required commands
for cmd in curl jq gdate; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "Error: $cmd is required but not installed. Aborting."
        exit 1
    fi
done

# Load environment variables from .env file
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi
# Load configuration from configuration file
INSTANCE_LIMITS_FILE="instance_limits.conf"

# Load configuration from environment variables
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
    echo "Processing instance: $INSTANCE_ID"

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

    echo "Current snapshot count for instance $INSTANCE_ID: $SNAPSHOT_COUNT"
    echo "Snapshot limit: $SNAPSHOT_LIMIT"

    # If the number of snapshots is greater than or equal to the limit, delete the oldest one
    if [ "$SNAPSHOT_COUNT" -ge "$SNAPSHOT_LIMIT" ]; then
        if [ "$dry_run" = true ]; then
            echo "[Dry run] Would delete oldest snapshot: $OLDEST_SNAPSHOT_ID"
        else
            echo "Deleting oldest snapshot: $OLDEST_SNAPSHOT_ID"
            delete_response=$(vultr_api_call DELETE "snapshots/${OLDEST_SNAPSHOT_ID}")
            if [ $? -ne 0 ]; then
                echo "Error: Failed to delete snapshot"
                continue
            fi
            echo "Snapshot deleted successfully"
        fi
    fi

    # Create a new snapshot
    if [ "$dry_run" = true ]; then
        echo "[Dry run] Would create new snapshot with description: $SNAPSHOT_DESCRIPTION"
    else
        echo "Creating new snapshot with description: $SNAPSHOT_DESCRIPTION"
        create_response=$(vultr_api_call POST "snapshots" \
            "{\"instance_id\":\"$INSTANCE_ID\",\"description\":\"$SNAPSHOT_DESCRIPTION\"}")
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create snapshot"
            continue
        fi
        new_snapshot_id=$(echo "$create_response" | jq -r '.snapshot.id')
        echo "New snapshot created successfully with ID: $new_snapshot_id"
    fi

    echo "Finished processing instance: $INSTANCE_ID"
    echo "-------------------------------------------"
done

echo "All instances processed."
