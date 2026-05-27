import os
from pathlib import Path
from dotenv import load_dotenv

# .env ファイルをロード
env_path = Path(__file__).parent.parent.parent / ".env"
load_dotenv(dotenv_path=env_path)

class Settings:
    DB_HOST: str = os.getenv("DB_HOST", "localhost")
    DB_PORT: str = os.getenv("DB_PORT", "5432")
    DB_USER: str = os.getenv("DB_USER", "safeway_user")
    DB_PASSWORD: str = os.getenv("DB_PASSWORD", "safeway_pass")
    DB_NAME: str = os.getenv("DB_NAME", "safeway_db")
    DATABASE_URL: str = os.getenv(
        "DATABASE_URL", 
        f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    )

settings = Settings()
