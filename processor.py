import io
import re
from typing import List, Tuple
from pypdf import PdfReader

# Simple keyword lists for tag extraction heuristic
KEYWORD_TAG_MAP = {
    r"\binvoice\b|\bbill\b|\breceipt\b": "financial",
    r"\bcontract\b|\bagreement\b|\blegal\b|\bterms\b": "legal",
    r"\bresume\b|\bcv\b|\bportfolio\b": "career",
    r"\breport\b|\banalysis\b|\bannual\b": "report",
    r"\bmanual\b|\bguide\b|\btutorial\b|\bhowto\b": "documentation",
    r"\bmedical\b|\bhealth\b|\bpatient\b|\bclinical\b": "medical",
    r"\bcode\b|\bprogramming\b|\bsoftware\b|\bdeveloper\b": "technology"
}

def extract_tags_from_text(text: str, file_type: str) -> List[str]:
    """Extracts tags from text using regex heuristics, and appends the file type."""
    tags = {file_type}
    text_lower = text.lower()
    
    for pattern, tag in KEYWORD_TAG_MAP.items():
        if re.search(pattern, text_lower):
            tags.add(tag)
            
    # If no specific tags were found, add a fallback tag
    if len(tags) == 1:
        tags.add("general")
        
    return list(tags)

def process_text_file(content: bytes) -> Tuple[str, int]:
    """Processes plain text files."""
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        try:
            text = content.decode("latin-1")
        except Exception:
            text = "[Error decoding text content]"
            
    words = text.split()
    word_count = len(words)
    return text, word_count

def process_pdf_file(content: bytes) -> Tuple[str, int]:
    """Extracts text from PDF using pypdf."""
    pdf_file = io.BytesIO(content)
    try:
        reader = PdfReader(pdf_file)
        text_parts = []
        for i, page in enumerate(reader.pages):
            page_text = page.extract_text()
            if page_text:
                text_parts.append(page_text)
        
        full_text = "\n".join(text_parts)
        if not full_text.strip():
            full_text = "[Scanned PDF or no extractable text found. Falling back to mock OCR]"
            
        words = full_text.split()
        word_count = len(words)
        return full_text, word_count
    except Exception as e:
        return f"[PDF parsing error: {str(e)}]", 0

def process_image_or_other(filename: str, file_type: str, content_size: int) -> Tuple[str, int]:
    """Simulates OCR text extraction for images and other unsupported binaries."""
    # Clean up filename for mocking text
    clean_name = re.sub(r"\.[a-zA-Z0-9]+$", "", filename)
    clean_name = re.sub(r"[-_]", " ", clean_name)
    
    # Generate mock OCR text
    mock_ocr_text = (
        f"--- MOCK OCR TEXT FOR {filename} ---\n"
        f"Detected Document Title: {clean_name.title()}\n"
        f"File format: {file_type.upper()}\n"
        f"Approximate content size: {content_size} bytes\n"
        f"Simulated OCR Status: Success\n"
        f"Extracted content: This is a simulated text representation "
        f"of the scanned image/binary document. The pipeline successfully processed "
        f"the file and identified it as a document related to {clean_name}."
    )
    
    word_count = len(mock_ocr_text.split())
    return mock_ocr_text, word_count

def process_document(filename: str, content: bytes, content_type: str) -> Tuple[str, int, List[str]]:
    """
    Main processing entry point. Returns (extracted_text, word_count, tags).
    """
    filename_lower = filename.lower()
    content_size = len(content)
    
    # Determine file type based on extension or content-type
    if filename_lower.endswith(".txt") or content_type == "text/plain":
        file_type = "txt"
        extracted_text, word_count = process_text_file(content)
    elif filename_lower.endswith(".pdf") or content_type == "application/pdf":
        file_type = "pdf"
        extracted_text, word_count = process_pdf_file(content)
        # If no text could be extracted, treat it like a scanned PDF/image
        if extracted_text == "[Scanned PDF or no extractable text found. Falling back to mock OCR]":
            mock_text, mock_words = process_image_or_other(filename, "scanned-pdf", content_size)
            extracted_text = mock_text
            word_count = mock_words
            file_type = "scanned-pdf"
    elif filename_lower.endswith((".png", ".jpg", ".jpeg", ".tiff", ".bmp")) or (content_type and content_type.startswith("image/")):
        file_type = "image"
        extracted_text, word_count = process_image_or_other(filename, file_type, content_size)
    else:
        file_type = "unknown"
        extracted_text, word_count = process_image_or_other(filename, file_type, content_size)
        
    # Heuristic tag extraction
    tags = extract_tags_from_text(extracted_text, file_type)
    if file_type == "image" or file_type == "scanned-pdf":
        tags.append("ocr-simulated")
        
    return extracted_text, word_count, tags
