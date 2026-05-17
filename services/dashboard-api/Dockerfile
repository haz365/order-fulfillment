FROM python:3.12-slim-bookworm AS builder
WORKDIR /build
RUN pip install --no-cache-dir --upgrade pip
COPY services/dashboard-api/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim-bookworm
RUN groupadd -r appuser && useradd -r -g appuser appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY --chown=appuser:appuser services/dashboard-api/main.py .
COPY --chown=appuser:appuser services/dashboard-api/static/ ./static/
ENV PYTHONUNBUFFERED=1
EXPOSE 8009
USER appuser
ENTRYPOINT ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8009", "--workers", "2"]