# Event-Driven Document Processing Pipeline on Google Cloud

This repository contains a production-ready, serverless event-driven document processing pipeline built on Google Cloud. It automatically processes uploaded documents (PDFs, TXT files, Images), extracts text and metadata, and streams the results into BigQuery.

## Architecture

1. **Ingestion**: A user uploads a file to a Google Cloud Storage (GCS) bucket.
2. **Trigger**: GCS sends an `OBJECT_FINALIZE` event to a Pub/Sub Topic.
3. **Queue**: A Pub/Sub Push Subscription forwards the event envelope to a FastAPI application running on Cloud Run.
4. **Processing**: The FastAPI service downloads the file from GCS, determines the file type, parses the text (with `pypdf` for PDFs, native parsing for text, and simulated OCR for images), and extracts metadata tags.
5. **Storage**: The service streams metadata (GCS URI, filename, file type, word count, tags, timestamp, extracted text) into a BigQuery table.

```
[User Upload] ──> [GCS Ingestion Bucket]
                        │
                        ▼ (Event Trigger)
                  [Pub/Sub Topic]
                        │
                        ▼ (Push POST /pubsub)
                  [Cloud Run (FastAPI)] <── (Reads File) ── [GCS Ingestion Bucket]
                        │
                        ▼ (Streams Metadata Row)
                  [BigQuery Database]
```

---

## File Structure

- `src/`
  - `main.py`: FastAPI server handling health checks and Pub/Sub notifications.
  - `processor.py`: Parser/OCR logic handling TXT, PDF, and image extraction.
  - `models.py`: Pydantic definitions for incoming Pub/Sub JSON and outgoing metadata.
  - `requirements.txt`: Python package dependencies.
  - `Dockerfile`: Production docker build setup for Cloud Run.
- `bq_schema.json`: Schema for the BigQuery metadata table.
- `deploy.ps1`: Automated deployment script for Windows PowerShell.
- `deploy.sh`: Automated deployment script for macOS/Linux Bash.
- `test_local.py`: Script to test the application locally using mock Pub/Sub events.

---

## Local Development & Testing

You can test the entire pipeline logic locally without having GCP credentials by using the built-in simulated `LOCAL_DEV` mode.

### 1. Set Up Environment
Create a Python virtual environment and install the required dependencies:

```bash
# Create virtual environment
python -m venv venv

# Activate virtual environment
# On Windows (PowerShell):
.\venv\Scripts\Activate.ps1
# On macOS/Linux (Bash):
source venv/bin/activate

# Install dependencies
pip install -r src/requirements.txt
```

### 2. Start FastAPI Server
Start the local server in mock mode (`LOCAL_DEV=true`). This will simulate downloads from GCS and writes to BigQuery:

**Windows (PowerShell):**
```powershell
$env:LOCAL_DEV="true"
uvicorn src.main:app --host 127.0.0.1 --port 8080 --reload
```

**macOS/Linux (Bash):**
```bash
LOCAL_DEV=true uvicorn src.main:app --host 127.0.0.1 --port 8080 --reload
```

### 3. Run Simulated Event Tests
In a new terminal window (with the virtual environment active), execute the local test runner:

```bash
python test_local.py
```

This script sends sample GCS upload notification envelopes (for TXT, PDF, PNG, and ZIP files) to your local endpoint and prints the server's response. You will see simulated OCR extraction, file type classification, and tag generation outputs.

---

## Deployment to Google Cloud

The deployment script automatically enables required GCP APIs, creates the Cloud Storage bucket, provisions the BigQuery dataset and table, configures IAM permission bindings, builds/deploys the service to Cloud Run, and links GCS uploads to the Cloud Run service via Pub/Sub notifications.

### Prerequisites
- Install the [Google Cloud SDK](https://cloud.google.com/sdk/docs/install).
- Log in and set your default project:
  ```bash
  gcloud auth login
  gcloud config set project YOUR_PROJECT_ID
  ```

### Run Deployment Script

**Windows (PowerShell):**
```powershell
.\deploy.ps1
```

**macOS/Linux (Bash):**
```bash
chmod +x deploy.sh
./deploy.sh
```

---

## Verifying the Pipeline in Google Cloud

Once deployment finishes successfully:

1. **Upload a file to the created GCS Bucket**:
   ```bash
   # Create a test file
   echo "This is a test invoice document for the technical team." > invoice_test.txt
   
   # Copy the file to your GCS bucket
   gcloud storage cp invoice_test.txt gs://YOUR_PROJECT_ID-document-ingestion/
   ```

2. **Verify processing in Cloud Run logs**:
   Go to the Google Cloud Console -> Cloud Run -> `doc-processor` -> Logs. You should see entries indicating:
   - Pub/Sub message received
   - File downloaded from GCS
   - Text processed (Word count, Tags: `['txt', 'financial', 'technology']`)
   - Metadata successfully written to BigQuery

3. **Verify data in BigQuery**:
   Go to the BigQuery console and run the following query:
   ```sql
   SELECT * FROM `document_processing.metadata` ORDER BY processed_at DESC LIMIT 10;
   ```
   You should see a new row for your uploaded file containing the extracted metadata, word count, tags array, and full text!
