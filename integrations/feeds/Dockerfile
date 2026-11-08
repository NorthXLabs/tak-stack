# One image for every feed. Each service in compose.yaml runs a different script.
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py .
ENV PYTHONUNBUFFERED=1
