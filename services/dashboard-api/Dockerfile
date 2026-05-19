FROM python:3.12-slim-bookworm@sha256:d193c6f51a7dbd10395d6328de3a7edb0516fb0608ca138036576f574c3e07d2 AS builder
WORKDIR /build
RUN pip install --no-cache-dir --upgrade pip
COPY services/dashboard-api/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM gcr.io/distroless/python3-debian12@sha256:7d1042ce588ab97019fe95c24ffca7bc5a82ccdac572511d5e09bda4435c89c5
WORKDIR /app
COPY --from=builder /install/lib/python3.12/site-packages /app/site-packages
COPY --from=builder /install/bin /usr/local/bin
COPY services/dashboard-api/main.py .
COPY services/dashboard-api/static/ ./static/
ENV PYTHONPATH=/app/site-packages
ENV PYTHONUNBUFFERED=1
EXPOSE 8009
ENTRYPOINT ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8009", "--workers", "2"]