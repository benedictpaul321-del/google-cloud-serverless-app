import os
import base64
import json
import logging
from datetime import datetime
from fastapi import FastAPI, HTTPException, status
from google.cloud import storage, bigquery
from google.api_core.exceptions import GoogleAPIError

from src.models import PubSubEnvelope, DocumentMetadata
from src.processor import process_document

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI(title="Event-Driven Document Processor")

# Load environment configuration
PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("PROJECT_ID")
DATASET_ID = os.getenv("BQ_DATASET", "document_processing")
TABLE_ID = os.getenv("BQ_TABLE", "metadata")
LOCAL_DEV = os.getenv("LOCAL_DEV", "false").lower() == "true"

# Initialize GCP clients
storage_client = None
bq_client = None

if not LOCAL_DEV:
    try:
        storage_client = storage.Client()
        bq_client = bigquery.Client()
        logger.info("GCP clients initialized successfully.")
    except Exception as e:
        logger.warning(
            f"Failed to initialize GCP clients. Running in fallback mode or check credentials: {str(e)}"
        )
else:
    logger.info("Running in LOCAL_DEV mode. GCS and BigQuery interactions will be simulated.")

@app.get("/")
def health_check():
    """Health check / warmup endpoint."""
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "local_dev": LOCAL_DEV,
        "config": {
            "project_id": PROJECT_ID,
            "dataset_id": DATASET_ID,
            "table_id": TABLE_ID
        }
    }

@app.post("/pubsub", status_code=status.HTTP_200_OK)
async def process_pubsub_message(envelope: PubSubEnvelope):
    """
    Receives Pub/Sub push subscription notifications.
    Decodes the message, extracts GCS object details, parses the document,
    and inserts the metadata into BigQuery.
    """
    # 1. Parse and decode the Pub/Sub envelope
    pubsub_msg = envelope.message
    if not pubsub_msg.data:
        logger.error("Empty Pub/Sub message data received.")
        raise HTTPException(status_code=400, detail="Invalid Pub/Sub message: empty data.")

    try:
        decoded_data = base64.b64decode(pubsub_msg.data).decode("utf-8")
        gcs_event = json.loads(decoded_data)
        logger.info(f"Received GCS Event Notification: {json.dumps(gcs_event, indent=2)}")
    except Exception as e:
        logger.error(f"Failed to decode/parse Pub/Sub message data: {str(e)}")
        raise HTTPException(status_code=400, detail=f"Bad request: {str(e)}")

    # Extract bucket and object name from the event
    bucket_name = gcs_event.get("bucket")
    object_name = gcs_event.get("name")
    content_type = gcs_event.get("contentType", "application/octet-stream")
    
    if not bucket_name or not object_name:
        logger.warning("GCS event does not contain bucket or name. Skipping process.")
        return {"status": "skipped", "reason": "missing bucket or object name"}

    # Avoid processing directories or placeholder files
    if object_name.endswith("/"):
        logger.info(f"Skipping directory placeholder: {object_name}")
        return {"status": "skipped", "reason": "directory placeholder"}

    gcs_uri = f"gs://{bucket_name}/{object_name}"
    logger.info(f"Starting processing for document: {gcs_uri}")

    # 2. Ingestion: Download file content from GCS
    file_content = b""
    if LOCAL_DEV:
        logger.info(f"[SIMULATED] Downloading {gcs_uri} from GCS...")
        # Simulate file content based on extension
        if object_name.lower().endswith(".txt"):
            file_content = b"Invoice details:\nAmount Due: $1,250.00\nPayment terms: 30 days\nPlease remit payment to invoice@example.com."
        elif object_name.lower().endswith(".pdf"):
            # Dummy PDF signature for pypdf (causes simple parser warning/mock fallback, which is fine)
            file_content = b"%PDF-1.4\n%...\n"
        else:
            file_content = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00"
    else:
        try:
            bucket = storage_client.bucket(bucket_name)
            blob = bucket.blob(object_name)
            if not blob.exists():
                logger.error(f"Blob {object_name} not found in bucket {bucket_name}.")
                raise HTTPException(status_code=404, detail="File not found in GCS.")
            
            file_content = blob.download_as_bytes()
            logger.info(f"Successfully downloaded {len(file_content)} bytes for {object_name}")
        except GoogleAPIError as e:
            logger.error(f"GCS Download failed: {str(e)}")
            raise HTTPException(status_code=500, detail=f"GCS storage access error: {str(e)}")
        except Exception as e:
            logger.error(f"Unexpected error fetching GCS file: {str(e)}")
            raise HTTPException(status_code=500, detail=f"Internal GCS fetch error: {str(e)}")

    # 3. Processor: Extract text and compile metadata
    try:
        extracted_text, word_count, tags = process_document(object_name, file_content, content_type)
        logger.info(f"Processed file. Words: {word_count}. Tags: {tags}")
    except Exception as e:
        logger.error(f"Document processing failed: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Document parsing error: {str(e)}")

    metadata = DocumentMetadata(
        gcs_uri=gcs_uri,
        filename=object_name,
        file_type=object_name.split(".")[-1].lower() if "." in object_name else "unknown",
        word_count=word_count,
        tags=tags,
        extracted_text=extracted_text
    )

    # 4. Storage: Stream metadata into BigQuery
    row_data = {
        "gcs_uri": metadata.gcs_uri,
        "filename": metadata.filename,
        "file_type": metadata.file_type,
        "processed_at": metadata.processed_at.isoformat(),
        "word_count": metadata.word_count,
        "tags": metadata.tags,
        "extracted_text": metadata.extracted_text
    }

    if LOCAL_DEV:
        logger.info(f"[SIMULATED] Writing metadata to BigQuery: {json.dumps(row_data, indent=2)}")
    else:
        if not bq_client:
            logger.error("BigQuery client is not initialized.")
            raise HTTPException(status_code=500, detail="BigQuery database client unavailable.")
        
        try:
            # Table reference: project.dataset.table
            table_ref = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
            errors = bq_client.insert_rows_json(table_ref, [row_data])
            if errors:
                logger.error(f"BigQuery streaming insert errors: {errors}")
                raise HTTPException(status_code=500, detail=f"BigQuery insert failed: {str(errors)}")
            logger.info("Successfully streamed metadata to BigQuery.")
        except GoogleAPIError as e:
            logger.error(f"BigQuery operation failed: {str(e)}")
            raise HTTPException(status_code=500, detail=f"BigQuery database error: {str(e)}")
        except Exception as e:
            logger.error(f"Unexpected error writing to BigQuery: {str(e)}")
            raise HTTPException(status_code=500, detail=f"Internal database write error: {str(e)}")

    return {
        "status": "success",
        "processed_file": metadata.filename,
        "word_count": metadata.word_count,
        "tags_extracted": metadata.tags
    }
