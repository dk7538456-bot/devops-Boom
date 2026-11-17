from fastapi.testclient import TestClient
from moto import mock_aws

from app.main import app, table


@mock_aws
def test_task_lifecycle_and_metrics():
    table.create_table(
        TableName=table.name,
        KeySchema=[{"AttributeName": "task_id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "task_id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    with TestClient(app) as client:
        assert client.get("/health/live").json()["status"] == "ok"
        assert client.get("/health/ready").json()["status"] == "ready"

        created = client.post("/api/v1/tasks", json={"title": "Ship the platform", "priority": "high"})
        assert created.status_code == 201
        task = created.json()
        assert task["status"] == "todo"
        assert created.headers["x-request-id"]

        changed = client.patch(f"/api/v1/tasks/{task['task_id']}", json={"status": "done"})
        assert changed.status_code == 200
        assert changed.json()["status"] == "done"

        metrics = client.get("/api/v1/metrics").json()
        assert metrics["tasks_total"] == 1
        assert metrics["tasks_by_status"]["done"] == 1

        assert client.delete(f"/api/v1/tasks/{task['task_id']}").status_code == 204
        assert client.delete(f"/api/v1/tasks/{task['task_id']}").status_code == 404


def test_create_validates_title():
    with TestClient(app) as client:
        response = client.post("/api/v1/tasks", json={"title": "x"})
    assert response.status_code == 422
