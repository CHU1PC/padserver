import os

import psycopg
from fastapi import FastAPI

app = FastAPI()
DSN = os.environ["DATABASE_URL"]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/db")
def db():
    with psycopg.connect(DSN, connect_timeout=5) as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS hits (id serial PRIMARY KEY)")
        conn.execute("INSERT INTO hits DEFAULT VALUES")
        count = conn.execute("SELECT count(*) FROM hits").fetchone()[0]
        version = conn.execute("SHOW server_version").fetchone()[0]
    return {"host": "db", "postgres": version, "hits": count}
