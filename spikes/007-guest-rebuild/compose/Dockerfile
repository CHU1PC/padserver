FROM python:3.13-alpine
RUN pip install --no-cache-dir fastapi uvicorn "psycopg[binary]"
WORKDIR /app
COPY app.py .
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
