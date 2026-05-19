# SafeWay

「最短」ではなく「安心」を提示する、歩行者・自転車向けの安全ナビゲーションアプリ。

GPA（ぐんまプログラミングアワード）2026 アプリ部門 応募作品。

## 構成

```
SafeWay/
├── backend/     # FastAPI + YOLO (Python)
├── frontend/    # Flutter アプリ (Dart)
└── docs/        # API仕様書等
```

## セットアップ

### バックエンド

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate      # Windows
pip install -r requirements.txt
uvicorn app.main:app --reload
```

### フロントエンド

```bash
cd frontend
flutter pub get
flutter run
```
