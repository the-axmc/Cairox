FROM python:3.11-slim

WORKDIR /app

RUN apt-get update -y >/dev/null && \
    apt-get install -y build-essential curl >/dev/null && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PYTHONUNBUFFERED=1

CMD ["python", "src/agent.py"]
