# SafeWay Backend

FastAPI + YOLO v26 によるバックエンドサーバー。

## 起動方法

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

API ドキュメント: http://localhost:8000/docs
