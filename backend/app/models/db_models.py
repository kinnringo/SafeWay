from datetime import datetime
from sqlalchemy import Column, Integer, String, Float, DateTime, ForeignKey, Boolean, BigInteger, UniqueConstraint
from sqlalchemy.orm import relationship
from geoalchemy2 import Geometry
from app.core.database import Base

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    password_hash = Column(String, nullable=False)
    coins = Column(Integer, default=0, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    detections = relationship("Detection", back_populates="user")
    coin_transactions = relationship("CoinTransaction", back_populates="user")


class CoinTransaction(Base):
    __tablename__ = "coin_transactions"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    amount = Column(Integer, nullable=False)
    reason = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="coin_transactions")


class Detection(Base):
    __tablename__ = "detections"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    label = Column(String, nullable=False)
    confidence = Column(Float, nullable=False)
    image_path = Column(String, nullable=True)
    geom = Column(Geometry(geometry_type='POINT', srid=4326), nullable=False)
    # 物体の GPS 位置推定精度
    #   "high": コンパス方位角 + 焦点距離から位置を推定（精度良好）
    #   "low":  方位角または焦点距離が不明で撮影者位置を使用（精度低）
    position_accuracy = Column(String, default="low", nullable=False)
    # カメラから物体までの推定水平距離（メートル）
    # position_accuracy が "low" の場合は None
    estimated_distance_m = Column(Float, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="detections")
    safety_point = relationship("SafetyPoint", back_populates="detection", uselist=False)



class CrimeReport(Base):
    __tablename__ = "crime_reports"

    id = Column(Integer, primary_key=True, index=True)
    event_type = Column(String, nullable=False)
    description = Column(String, nullable=True)
    geom = Column(Geometry(geometry_type='POINT', srid=4326), nullable=False)
    occurred_at = Column(DateTime, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    safety_point = relationship("SafetyPoint", back_populates="crime_report", uselist=False)


class SafetyPoint(Base):
    __tablename__ = "safety_points"

    id = Column(Integer, primary_key=True, index=True)
    source_type = Column(String, nullable=False)
    
    detection_id = Column(Integer, ForeignKey("detections.id"), nullable=True)
    crime_report_id = Column(Integer, ForeignKey("crime_reports.id"), nullable=True)
    
    score_modifier = Column(Float, nullable=False)
    influence_radius_m = Column(Float, default=20.0, nullable=False)
    is_road_attribute = Column(Boolean, default=False, nullable=False)
    geom = Column(Geometry(geometry_type='POINT', srid=4326), nullable=False)
    is_visible = Column(Boolean, default=True, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)

    detection = relationship("Detection", back_populates="safety_point")
    crime_report = relationship("CrimeReport", back_populates="safety_point")


class Edge(Base):
    __tablename__ = "road_edges"

    id = Column(Integer, primary_key=True, index=True)
    osm_id = Column(BigInteger, index=True, nullable=True)
    source_node = Column(Integer, nullable=True)
    target_node = Column(Integer, nullable=True)
    length = Column(Float, nullable=False)
    geom = Column(Geometry(geometry_type='LINESTRING', srid=4326), nullable=False)
    base_safety_score = Column(Float, default=0.5, nullable=False)
    dynamic_safety_score = Column(Float, default=0.0, nullable=False)
    safety_score = Column(Float, default=0.5, nullable=False)
    routing_cost = Column(Float, nullable=True)


class CoverageCell(Base):
    """情報空白地帯可視化用の事前集計テーブル

    グリッドセルごとに SafetyPoint の件数を保持する。
    SafetyPoint が追加されるたびにインクリメンタルに更新される。
    フロントからの GET /api/coverage では、このテーブルを参照するだけで
    データ量に依存しない高速なレスポンスを実現する。
    """
    __tablename__ = "coverage_cells"

    id = Column(Integer, primary_key=True, index=True)
    cell_lat = Column(Float, nullable=False)      # セル南端の緯度（丸め値）
    cell_lng = Column(Float, nullable=False)       # セル西端の経度（丸め値）
    cell_size = Column(Float, nullable=False)      # セルサイズ（度）
    point_count = Column(Integer, default=0, nullable=False)  # セル内の SafetyPoint 数
    geom = Column(Geometry(geometry_type='POLYGON', srid=4326), nullable=True)  # セルのポリゴン（空間検索用）

    __table_args__ = (
        UniqueConstraint('cell_lat', 'cell_lng', 'cell_size', name='uix_coverage_cell'),
    )

