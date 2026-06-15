FROM python:3.11-slim

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

# Set working directory to /app
WORKDIR /app

# Copy dependency definition and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application files into /app/src/
COPY . ./src/

# Run the web service on container startup using Uvicorn
CMD exec uvicorn src.main:app --host 0.0.0.0 --port ${PORT:-8080}
