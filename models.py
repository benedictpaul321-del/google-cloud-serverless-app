from pydantic import BaseModel, Field
from typing import List, Optional
from datetime import datetime

class PubSubMessage(BaseModel):
    data: str
    messageId: str
    publishTime: str
    attributes: Optional[dict] = None

class PubSubEnvelope(BaseModel):
    message: PubSubMessage
    subscription: str

class GCSEvent(BaseModel):
    kind: str
    id: str
    name: str
    bucket: str
    generation: str
    contentType: Optional[str] = None
    size: Optional[str] = None
    timeCreated: Optional[str] = None
    updated: Optional[str] = None

class DocumentMetadata(BaseModel):
    gcs_uri: str
    filename: str
    file_type: str
    processed_at: datetime = Field(default_factory=datetime.utcnow)
    word_count: int
    tags: List[str]
    extracted_text: str
