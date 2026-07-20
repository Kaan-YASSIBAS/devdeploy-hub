FROM python:3.12-alpine

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN apk upgrade --no-cache libcrypto3 libssl3 libexpat \
    && apk add --no-cache git

COPY requirements.txt constraints.txt ./
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt -c constraints.txt

RUN addgroup -g 10001 -S app \
    && adduser -u 10001 -S -D -G app -h /app -s /sbin/nologin app

COPY --chown=app:app . .

USER 10001:10001

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
