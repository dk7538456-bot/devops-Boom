"""TaskForge: an observable, cloud-ready task service."""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
TABLE_NAME = os.getenv("TASKS_TABLE", "taskforge-tasks")
AWS_REGION = os.getenv("AWS_REGION", "ap-south-1")
_endpoint = os.getenv("DYNAMODB_ENDPOINT_URL")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {"timestamp": datetime.now(timezone.utc).isoformat(), "level": record.levelname,
                   "logger": record.name, "message": record.getMessage()}
        for key in ("request_id", "method", "path", "status_code", "duration_ms", "task_id"):
            if hasattr(record, key): payload[key] = getattr(record, key)
        if record.exc_info: payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), handlers=[handler], force=True)
log = logging.getLogger("taskforge")
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION, endpoint_url=_endpoint)
table = dynamodb.Table(TABLE_NAME)
started_at = time.time()


class TaskCreate(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    description: str = Field(default="", max_length=1000)
    priority: Literal["low", "medium", "high"] = "medium"


class TaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=3, max_length=120)
    description: str | None = Field(default=None, max_length=1000)
    priority: Literal["low", "medium", "high"] | None = None
    status: Literal["todo", "in_progress", "done"] | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    log.info("service_started", extra={"app_version": APP_VERSION})
    yield
    log.info("service_stopped")


app = FastAPI(title="TaskForge API", version=APP_VERSION,
              description="A production-minded task API demonstrating AWS and DevOps practices.",
              lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=os.getenv("CORS_ORIGINS", "*").split(","),
                   allow_methods=["GET", "POST", "PATCH", "DELETE"], allow_headers=["*"])
web_dir = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=web_dir), name="static")


@app.middleware("http")
async def request_context(request: Request, call_next):
    request_id = request.headers.get("x-request-id", str(uuid.uuid4()))[:80]
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        log.exception("request_failed", extra={"request_id": request_id, "method": request.method, "path": request.url.path})
        raise
    elapsed = round((time.perf_counter() - start) * 1000, 2)
    response.headers["X-Request-ID"] = request_id
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    log.info("request_complete", extra={"request_id": request_id, "method": request.method,
             "path": request.url.path, "status_code": response.status_code, "duration_ms": elapsed})
    return response


def db_error(exc: Exception) -> HTTPException:
    log.exception("database_operation_failed")
    return HTTPException(status_code=503, detail="Task storage is temporarily unavailable")


@app.get("/", include_in_schema=False)
def index(): return FileResponse(web_dir / "index.html")


@app.get("/health/live", tags=["operations"])
def liveness(): return {"status": "ok", "service": "taskforge", "version": APP_VERSION}


@app.get("/health/ready", tags=["operations"])
def readiness():
    try:
        table.load()
        return {"status": "ready", "database": "reachable", "region": AWS_REGION}
    except (BotoCoreError, ClientError) as exc:
        raise db_error(exc)


@app.get("/api/v1/metrics", tags=["operations"])
def metrics():
    try:
        items = table.scan(ProjectionExpression="#s", ExpressionAttributeNames={"#s": "status"}).get("Items", [])
        counts = {status: sum(1 for item in items if item.get("status") == status) for status in ("todo", "in_progress", "done")}
        return {"uptime_seconds": round(time.time() - started_at), "tasks_total": len(items), "tasks_by_status": counts}
    except (BotoCoreError, ClientError) as exc: raise db_error(exc)


@app.get("/api/v1/tasks", tags=["tasks"])
def list_tasks(status: Literal["todo", "in_progress", "done"] | None = None):
    try:
        result = table.scan()
        tasks = result.get("Items", [])
        if status: tasks = [task for task in tasks if task["status"] == status]
        tasks.sort(key=lambda task: task["created_at"], reverse=True)
        return {"items": tasks, "count": len(tasks)}
    except (BotoCoreError, ClientError) as exc: raise db_error(exc)


@app.post("/api/v1/tasks", status_code=201, tags=["tasks"])
def create_task(payload: TaskCreate):
    now = datetime.now(timezone.utc).isoformat()
    task = {"task_id": str(uuid.uuid4()), **payload.model_dump(), "status": "todo", "created_at": now, "updated_at": now}
    try:
        table.put_item(Item=task, ConditionExpression="attribute_not_exists(task_id)")
        log.info("task_created", extra={"task_id": task["task_id"]})
        return task
    except (BotoCoreError, ClientError) as exc: raise db_error(exc)


@app.patch("/api/v1/tasks/{task_id}", tags=["tasks"])
def update_task(task_id: str, payload: TaskUpdate):
    changes = payload.model_dump(exclude_unset=True, exclude_none=True)
    if not changes: raise HTTPException(400, "Provide at least one field to update")
    changes["updated_at"] = datetime.now(timezone.utc).isoformat()
    names = {f"#{key}": key for key in changes}
    values = {f":{key}": value for key, value in changes.items()}
    expression = "SET " + ", ".join(f"#{key} = :{key}" for key in changes)
    try:
        result = table.update_item(Key={"task_id": task_id}, UpdateExpression=expression,
            ExpressionAttributeNames=names, ExpressionAttributeValues=values,
            ConditionExpression="attribute_exists(task_id)", ReturnValues="ALL_NEW")
        return result["Attributes"]
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException": raise HTTPException(404, "Task not found")
        raise db_error(exc)
    except BotoCoreError as exc: raise db_error(exc)


@app.delete("/api/v1/tasks/{task_id}", status_code=204, tags=["tasks"])
def delete_task(task_id: str):
    try:
        table.delete_item(Key={"task_id": task_id}, ConditionExpression="attribute_exists(task_id)")
        return Response(status_code=204)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException": raise HTTPException(404, "Task not found")
        raise db_error(exc)
    except BotoCoreError as exc: raise db_error(exc)
