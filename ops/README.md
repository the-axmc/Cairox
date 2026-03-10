# Self‑Hosted Stack (Docker Compose)

From the repo root:

```bash
python scripts/validate_env.py --profile all --env .env
docker compose -f ops/docker-compose.yml build
docker compose -f ops/docker-compose.yml up -d
```

Services:
- `frontend` on `http://localhost:8080`
- `middleware` on `http://localhost:8787`
- `indexer` (SQLite at `indexer-data` volume)
- `oracle-agent` (runs continuously)

Environment variables come from `../.env`.
