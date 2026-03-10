FROM node:20-bookworm

RUN apt-get update -y >/dev/null && \
  apt-get install -y python3 python3-venv python3-pip git curl ca-certificates >/dev/null && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install relayer deps
COPY relayer/package.json /app/relayer/package.json
WORKDIR /app/relayer
RUN npm install --no-audit --no-fund

# Install zk deps
WORKDIR /app/zk
COPY zk/package.json /app/zk/package.json
COPY zk/package-lock.json /app/zk/package-lock.json
RUN npm ci --no-audit --no-fund

# Install garaga for calldata
RUN pip3 install --no-cache-dir garaga

# Copy repo
WORKDIR /app
COPY . /app

WORKDIR /app/relayer
EXPOSE 8788

CMD ["node", "server.js"]
