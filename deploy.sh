#!/usr/bin/env bash
# deploy.sh - Unix Bash Deployment Script
# Provisions GCP resources and deploys the FastAPI app to Cloud Run.

set -euo pipefail

# Text colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}   Event-Driven Document Processor Deployment Script      ${NC}"
echo -e "${CYAN}==========================================================${NC}"

# 1. Configuration & Default Values
ProjectID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "")}"
if [ -z "$ProjectID" ]; then
    if [ "${CI:-false}" = "true" ]; then
        echo "Error: PROJECT_ID environment variable is not set and running in non-interactive CI."
        exit 1
    fi
    read -p "Enter your Google Cloud Project ID: " ProjectID
    if [ -z "$ProjectID" ]; then
        echo "Project ID is required. Exiting."
        exit 1
    fi
fi
echo -e "Using Project ID: ${GREEN}$ProjectID${NC}"


Region="us-central1"
IngestionBucket="$ProjectID-document-ingestion"
PubSubTopic="document-upload-topic"
PubSubSubscription="document-upload-push-sub"
BqDataset="document_processing"
BqTable="metadata"
CloudRunService="doc-processor"

# 2. Enable Required APIs
echo -e "\n${YELLOW}[Step 1] Enabling Google Cloud APIs...${NC}"
gcloud services enable \
    run.googleapis.com \
    pubsub.googleapis.com \
    storage.googleapis.com \
    artifactregistry.googleapis.com \
    bigquery.googleapis.com \
    cloudbuild.googleapis.com \
    --project="$ProjectID"

# 3. Create Storage Ingestion Bucket
echo -e "\n${YELLOW}[Step 2] Creating Cloud Storage Bucket: gs://$IngestionBucket...${NC}"
if gcloud storage buckets describe "gs://$IngestionBucket" --project="$ProjectID" &>/dev/null; then
    echo -e "Bucket gs://$IngestionBucket already exists."
else
    gcloud storage buckets create "gs://$IngestionBucket" --project="$ProjectID" --location="$Region"
    echo -e "${GREEN}Created bucket gs://$IngestionBucket.${NC}"
fi

# 4. Create BigQuery Dataset & Table
echo -e "\n${YELLOW}[Step 3] Setting up BigQuery...${NC}"
if bq show --project_id="$ProjectID" "$BqDataset" &>/dev/null; then
    echo -e "BigQuery dataset '$BqDataset' already exists."
else
    bq --project_id="$ProjectID" mk --dataset --location="$Region" "$BqDataset"
    echo -e "${GREEN}Created BigQuery dataset '$BqDataset'.${NC}"
fi

if bq show --project_id="$ProjectID" "$BqDataset.$BqTable" &>/dev/null; then
    echo -e "BigQuery table '$BqDataset.$BqTable' already exists."
else
    bq --project_id="$ProjectID" mk --table "$BqDataset.$BqTable" bq_schema.json
    echo -e "${GREEN}Created BigQuery table '$BqDataset.$BqTable' with schema.${NC}"
fi

# 5. Create Pub/Sub Topic
echo -e "\n${YELLOW}[Step 4] Creating Pub/Sub Topic: $PubSubTopic...${NC}"
if gcloud pubsub topics describe "$PubSubTopic" --project="$ProjectID" &>/dev/null; then
    echo -e "Pub/Sub topic '$PubSubTopic' already exists."
else
    gcloud pubsub topics create "$PubSubTopic" --project="$ProjectID"
    echo -e "${GREEN}Created Pub/Sub topic '$PubSubTopic'.${NC}"
fi

# 6. Build and Deploy Cloud Run service
echo -e "\n${YELLOW}[Step 5] Building and deploying Cloud Run Service...${NC}"
# Build the container via Cloud Build (no local Docker required)
gcloud builds submit src/ --tag="gcr.io/$ProjectID/$CloudRunService:latest" --project="$ProjectID"

# Deploy the image to Cloud Run
gcloud run deploy "$CloudRunService" \
    --image="gcr.io/$ProjectID/$CloudRunService:latest" \
    --region="$Region" \
    --platform=managed \
    --allow-unauthenticated \
    --set-env-vars="PROJECT_ID=$ProjectID,BQ_DATASET=$BqDataset,BQ_TABLE=$BqTable" \
    --project="$ProjectID"

# Retrieve the Cloud Run Service URL
CloudRunUrl=$(gcloud run services describe "$CloudRunService" --region="$Region" --project="$ProjectID" --format="value(status.url)")
echo -e "${GREEN}Cloud Run Service deployed to: $CloudRunUrl${NC}"

# 7. Authorize Cloud Storage to Publish to Pub/Sub
echo -e "\n${YELLOW}[Step 6] Granting storage service account publisher permission...${NC}"
GcsServiceAccount=$(gcloud storage service-agent --project="$ProjectID")
echo -e "GCS Service Agent: $GcsServiceAccount"

gcloud pubsub topics add-iam-policy-binding "$PubSubTopic" \
    --member="serviceAccount:$GcsServiceAccount" \
    --role="roles/pubsub.publisher" \
    --project="$ProjectID" >/dev/null

# 8. Create Cloud Storage notification trigger
echo -e "\n${YELLOW}[Step 7] Hooking up GCS notifications to Pub/Sub topic...${NC}"
if gcloud storage buckets notifications list "gs://$IngestionBucket" --project="$ProjectID" &>/dev/null; then
    echo -e "Notifications already configured for bucket gs://$IngestionBucket."
else
    gcloud storage buckets notifications create "gs://$IngestionBucket" --topic="$PubSubTopic" --event-types=OBJECT_FINALIZE --project="$ProjectID"
    echo -e "${GREEN}Created GCS notification trigger for $PubSubTopic.${NC}"
fi

# 9. Create Pub/Sub Push Subscription to Cloud Run
echo -e "\n${YELLOW}[Step 8] Creating Pub/Sub push subscription pointing to Cloud Run...${NC}"
PushUrl="$CloudRunUrl/pubsub"
if gcloud pubsub subscriptions describe "$PubSubSubscription" --project="$ProjectID" &>/dev/null; then
    echo -e "Pub/Sub subscription '$PubSubSubscription' already exists. Updating endpoint to $PushUrl..."
    gcloud pubsub subscriptions update "$PubSubSubscription" --push-endpoint="$PushUrl" --project="$ProjectID"
else
    gcloud pubsub subscriptions create "$PubSubSubscription" \
        --topic="$PubSubTopic" \
        --push-endpoint="$PushUrl" \
        --project="$ProjectID"
    echo -e "${GREEN}Created Push Subscription '$PubSubSubscription'.${NC}"
fi

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN}   Deployment Completed Successfully!                     ${NC}"
echo -e "${GREEN}   Ingestion Bucket: gs://$IngestionBucket                ${NC}"
echo -e "${GREEN}   BigQuery Table:   $ProjectID.$BqDataset.$BqTable       ${NC}"
echo -e "${GREEN}   Cloud Run URL:    $CloudRunUrl                         ${NC}"
echo -e "${GREEN}==========================================================${NC}"
