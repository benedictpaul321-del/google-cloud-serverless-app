# deploy.ps1 - Windows PowerShell Deployment Script
# Provisions GCP resources and deploys the FastAPI app to Cloud Run.

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Event-Driven Document Processor Deployment Script" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Configuration & Default Values
$ProjectID = $env:PROJECT_ID
if (-not $ProjectID) {
    try {
        $ProjectID = (gcloud config get-value project)
    } catch {}
}
if (-not $ProjectID) {
    if ($env:CI -eq "true") {
        Write-Error "Error: PROJECT_ID environment variable is not set and running in non-interactive CI."
        exit 1
    }
    $ProjectID = Read-Host "Enter your Google Cloud Project ID"
    if (-not $ProjectID) {
        Write-Error "Project ID is required. Exiting."
        exit 1
    }
}
Write-Host "Using Project ID: $ProjectID" -ForegroundColor Green

$Region = "us-central1"
$IngestionBucket = "$ProjectID-document-ingestion"
$PubSubTopic = "document-upload-topic"
$PubSubSubscription = "document-upload-push-sub"
$BqDataset = "document_processing"
$BqTable = "metadata"
$CloudRunService = "doc-processor"

# 2. Enable Required APIs
Write-Host "`n[Step 1] Enabling Google Cloud APIs..." -ForegroundColor Yellow
gcloud services enable `
    run.googleapis.com `
    pubsub.googleapis.com `
    storage.googleapis.com `
    artifactregistry.googleapis.com `
    bigquery.googleapis.com `
    cloudbuild.googleapis.com `
    --project=$ProjectID

# 3. Create Storage Ingestion Bucket
Write-Host "`n[Step 2] Creating Cloud Storage Bucket: gs://$IngestionBucket..." -ForegroundColor Yellow
$BucketExists = $null
try {
    $BucketExists = gcloud storage buckets describe gs://$IngestionBucket --project=$ProjectID 2>$null
} catch {}

if ($BucketExists) {
    Write-Host "Bucket gs://$IngestionBucket already exists." -ForegroundColor Gray
} else {
    gcloud storage buckets create gs://$IngestionBucket --project=$ProjectID --location=$Region
    Write-Host "Created bucket gs://$IngestionBucket." -ForegroundColor Green
}

# 4. Create BigQuery Dataset & Table
Write-Host "`n[Step 3] Setting up BigQuery..." -ForegroundColor Yellow
$DatasetExists = bq show --project_id=$ProjectID $BqDataset 2>$null
if ($DatasetExists) {
    Write-Host "BigQuery dataset '$BqDataset' already exists." -ForegroundColor Gray
} else {
    bq --project_id=$ProjectID mk --dataset --location=$Region $BqDataset
    Write-Host "Created BigQuery dataset '$BqDataset'." -ForegroundColor Green
}

$TableExists = bq show --project_id=$ProjectID "$BqDataset.$BqTable" 2>$null
if ($TableExists) {
    Write-Host "BigQuery table '$BqDataset.$BqTable' already exists." -ForegroundColor Gray
} else {
    bq --project_id=$ProjectID mk --table "$BqDataset.$BqTable" bq_schema.json
    Write-Host "Created BigQuery table '$BqDataset.$BqTable' with schema." -ForegroundColor Green
}

# 5. Create Pub/Sub Topic
Write-Host "`n[Step 4] Creating Pub/Sub Topic: $PubSubTopic..." -ForegroundColor Yellow
$TopicExists = $null
try {
    $TopicExists = gcloud pubsub topics describe $PubSubTopic --project=$ProjectID 2>$null
} catch {}

if ($TopicExists) {
    Write-Host "Pub/Sub topic '$PubSubTopic' already exists." -ForegroundColor Gray
} else {
    gcloud pubsub topics create $PubSubTopic --project=$ProjectID
    Write-Host "Created Pub/Sub topic '$PubSubTopic'." -ForegroundColor Green
}

# 6. Build and Deploy Cloud Run service
Write-Host "`n[Step 5] Building and deploying Cloud Run Service..." -ForegroundColor Yellow
# Build the container via Cloud Build (no local Docker required)
gcloud builds submit src/ --tag="gcr.io/$ProjectID/$CloudRunService:latest" --project=$ProjectID

# Deploy the image to Cloud Run
gcloud run deploy $CloudRunService `
    --image="gcr.io/$ProjectID/$CloudRunService:latest" `
    --region=$Region `
    --platform=managed `
    --allow-unauthenticated `
    --set-env-vars="PROJECT_ID=$ProjectID,BQ_DATASET=$BqDataset,BQ_TABLE=$BqTable" `
    --project=$ProjectID

# Retrieve the Cloud Run Service URL
$CloudRunUrl = (gcloud run services describe $CloudRunService --region=$Region --project=$ProjectID --format="value(status.url)")
Write-Host "Cloud Run Service deployed to: $CloudRunUrl" -ForegroundColor Green

# 7. Authorize Cloud Storage to Publish to Pub/Sub
Write-Host "`n[Step 6] Granting storage service account publisher permission..." -ForegroundColor Yellow
$GcsServiceAccount = (gcloud storage service-agent --project=$ProjectID)
Write-Host "GCS Service Agent: $GcsServiceAccount" -ForegroundColor Gray

gcloud pubsub topics add-iam-policy-binding $PubSubTopic `
    --member="serviceAccount:$GcsServiceAccount" `
    --role="roles/pubsub.publisher" `
    --project=$ProjectID | Out-Null

# 8. Create Cloud Storage notification trigger
Write-Host "`n[Step 7] Hooking up GCS notifications to Pub/Sub topic..." -ForegroundColor Yellow
# Check if notifications already exist
$NotificationList = gcloud storage buckets notifications list gs://$IngestionBucket --project=$ProjectID 2>$null
if ($NotificationList) {
    Write-Host "Notifications already configured for bucket gs://$IngestionBucket." -ForegroundColor Gray
} else {
    gcloud storage buckets notifications create gs://$IngestionBucket --topic=$PubSubTopic --event-types=OBJECT_FINALIZE --project=$ProjectID
    Write-Host "Created GCS notification trigger for $PubSubTopic." -ForegroundColor Green
}

# 9. Create Pub/Sub Push Subscription to Cloud Run
Write-Host "`n[Step 8] Creating Pub/Sub push subscription pointing to Cloud Run..." -ForegroundColor Yellow
$SubExists = $null
try {
    $SubExists = gcloud pubsub subscriptions describe $PubSubSubscription --project=$ProjectID 2>$null
} catch {}

$PushUrl = "$CloudRunUrl/pubsub"
if ($SubExists) {
    Write-Host "Pub/Sub subscription '$PubSubSubscription' already exists. Updating endpoint to $PushUrl..." -ForegroundColor Gray
    gcloud pubsub subscriptions update $PubSubSubscription --push-endpoint=$PushUrl --project=$ProjectID
} else {
    gcloud pubsub subscriptions create $PubSubSubscription `
        --topic=$PubSubTopic `
        --push-endpoint=$PushUrl `
        --project=$ProjectID
    Write-Host "Created Push Subscription '$PubSubSubscription'." -ForegroundColor Green
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   Deployment Completed Successfully!" -ForegroundColor Green
Write-Host "   Ingestion Bucket: gs://$IngestionBucket" -ForegroundColor Green
Write-Host "   BigQuery Table:   $ProjectID.$BqDataset.$BqTable" -ForegroundColor Green
Write-Host "   Cloud Run URL:    $CloudRunUrl" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
