"""デモおよびデバッグ専用 API および リモートコントロール Web 画面ルーター

プレゼン本番のデモ時において、地図上の任意位置をクリックするだけで
リアルタイムに危険情報（crime_reports）や街灯・歩道検出（detections）を登録し、
即時にクライアントアプリの警告通知や安全ルートスコアを反映するためのマスターコンソール。
"""
import logging
from datetime import datetime
from fastapi import APIRouter, Depends
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.score_config import SCORE_MODIFIERS, DEFAULT_SCORE_MODIFIER, INFLUENCE_RADIUS_M
from app.models.db_models import Detection, SafetyPoint
from app.models.schemas import DebugDetectionCreate, DebugDetectionResponse
from app.services.scoring import update_edge_scores_near_point
from app.services.coverage import update_coverage_cells

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post(
    "/api/detections/debug",
    response_model=DebugDetectionResponse,
    summary="デモ・デバッグ用の即時物体検出登録API",
    description="画像を介さず、クリックされた座標を推定完了位置（精度 High）として登録し、周囲の道路コスト・安全性スコアの再計算まですべて全自動で完結させるシミュレートAPI。",
    tags=["analyze"],
)
def create_debug_detection(
    payload: DebugDetectionCreate,
    db: Session = Depends(get_db),
):
    """ダミーの街灯・歩道等検出データを安全マップに即登録し、道路コストを更新する。"""
    obj_geom = f"SRID=4326;POINT({payload.lng} {payload.lat})"

    # 1. detections テーブルへ保存
    detection = Detection(
        user_id=None,
        label=payload.label,
        confidence=payload.confidence,
        image_path="demo_console_simulator",
        geom=obj_geom,
        position_accuracy="high",
        estimated_distance_m=0.0,
    )
    db.add(detection)
    db.flush()

    # 2. safety_points テーブルへ保存
    score_modifier = SCORE_MODIFIERS.get(payload.label.lower(), DEFAULT_SCORE_MODIFIER)

    safety_point = SafetyPoint(
        source_type="detections",
        detection_id=detection.id,
        score_modifier=score_modifier,
        influence_radius_m=INFLUENCE_RADIUS_M,
        is_road_attribute=True,
        geom=obj_geom,
        is_visible=True,
        updated_at=datetime.utcnow()
    )
    db.add(safety_point)
    db.commit()

    # 3. 周辺道路のコストを更新する（カバレッジは detections の DB トリガーで自動インクリメント）
    try:
        update_edge_scores_near_point(db, payload.lng, payload.lat)
        db.commit()
    except Exception as e:
        logger.warning("デバッガからのエリアコスト・道路エッジ再計算スキップ: %s", e)
        db.rollback()

    return DebugDetectionResponse(
        id=detection.id,
        label=detection.label,
        lat=payload.lat,
        lng=payload.lng,
        score_modifier=score_modifier,
        created_at=datetime.utcnow(),
    )


# ---------------------------------------------------------------------------
# デモ・デバッグ司令コンソール (UI 画面の提供)
# ---------------------------------------------------------------------------
@router.get("/demo", response_class=HTMLResponse, tags=["demo"])
def get_demo_console():
    """ SafeWay プレゼンテーション 統合デモ・シミュレートポータルを開く """
    return DEMO_CONSOLE_HTML


DEMO_CONSOLE_HTML = """
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SafeWay Debug & Demo Console</title>
    <!-- Leaflet Map CSS/JS -->
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <style>
        :root {
            --bg-body: #fafafa;
            --bg-surface: #ffffff;
            --border-color: #d8dede;
            --text-primary: #3b4151;
            --text-secondary: #707888;
            --accent-green: #49cc90;
            --accent-blue: #61affe;
            --accent-red: #f93e3e;
            --accent-dark: #2b313d;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Open Sans', 'Helvetica Neue', 'Meiryo', sans-serif; color: var(--text-primary); }
        body { background-color: var(--bg-body); display: flex; flex-direction: column; height: 100vh; overflow: hidden; font-size: 14px; }
        
        /* Header (Swagger / Docs style) */
        header { 
            background: #2b313d; 
            padding: 14px 28px; 
            display: flex; 
            align-items: center; 
            justify-content: space-between; 
            border-bottom: 1px solid #1f232d;
            z-index: 100;
        }
        .title-group { display: flex; align-items: center; gap: 14px; }
        .logo-badge { background: #89bf04; color: #ffffff; font-weight: bold; padding: 3px 10px; border-radius: 3px; font-size: 11px; text-transform: uppercase; }
        h1 { font-size: 18px; font-weight: bold; color: #ffffff; }
        .server-status { font-size: 12px; color: #a9b1c0; }

        /* Main Workspace */
        .main-container { display: flex; flex: 1; overflow: hidden; }
        
        /* Map Section */
        #map-container { flex: 1; position: relative; border-right: 1px solid var(--border-color); }
        #map { height: 100%; width: 100%; }
        .map-overlay-info { 
            position: absolute; top: 12px; left: 12px; z-index: 1000; 
            background: rgba(255, 255, 255, 0.92); border: 1px solid #c9d1d1;
            padding: 8px 14px; border-radius: 4px; font-size: 12px;
            box-shadow: 0 1px 4px rgba(0,0,0,0.1);
        }

        /* Sidebar / Controls */
        .sidebar { width: 480px; background: var(--bg-surface); display: flex; flex-direction: column; z-index: 10; }
        
        /* Mode Tabs */
        .tabs { display: flex; background: #f2f4f4; border-bottom: 1px solid var(--border-color); }
        .tab-btn { 
            flex: 1; padding: 12px 16px; background: transparent; border: none; 
            color: var(--text-secondary); font-size: 13px; font-weight: bold; cursor: pointer; 
            border-bottom: 2px solid transparent; transition: background 0.15s;
        }
        .tab-btn:hover { background: #e8eae9; color: var(--text-primary); }
        .tab-btn.active-crime { color: #d32f2f; border-bottom-color: #d32f2f; background: var(--bg-surface); }
        .tab-btn.active-detect { color: #0288d1; border-bottom-color: #0288d1; background: var(--bg-surface); }

        /* Form Content */
        .form-content { padding: 20px; flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 16px; }
        .tab-pane { display: none; flex-direction: column; gap: 16px; }
        .tab-pane.active { display: flex; }
        
        .field-group { display: flex; flex-direction: column; gap: 6px; }
        label { font-size: 12px; font-weight: bold; color: var(--text-primary); display: flex; justify-content: space-between; }
        .hint { font-size: 11px; font-weight: normal; color: var(--text-secondary); }
        
        input[type="text"], input[type="number"], select, textarea {
            background: #ffffff; border: 1px solid #cccccc; color: var(--text-primary);
            padding: 8px 10px; border-radius: 4px; font-size: 13px;
        }
        input:focus, select:focus, textarea:focus { outline: none; border-color: #49cc90; }
        input[disabled] { background: #f5f7f7; color: #888888; }
        textarea { height: 80px; resize: vertical; line-height: 1.5; }

        .coords-box { display: flex; gap: 8px; align-items: center; }
        .coords-box input { width: 100%; text-align: center; font-weight: bold; background: #f9fafe; border-color: #bbc7de; }

        /* Action Buttons */
        .btn-submit {
            padding: 10px 18px; border: none; border-radius: 4px; font-weight: bold; font-size: 13px; 
            color: #ffffff; cursor: pointer; transition: 0.15s; text-align: center; margin-top: 4px;
        }
        .btn-crime { background-color: #e53935; }
        .btn-crime:hover { background-color: #c62828; }
        
        .btn-detect { background-color: #1e88e5; }
        .btn-detect:hover { background-color: #1565c0; }

        .info-box {
            background: #f4f6f8; border: 1px solid #dcdfe3; border-radius: 4px; padding: 10px 12px; font-size: 12px; line-height: 1.6; color: #555555;
        }

        /* Log / Response Section */
        .log-section {
            height: 200px; background: #fafafa; border-top: 1px solid var(--border-color); 
            display: flex; flex-direction: column; font-family: 'Consolas', 'Monospace', monospace;
        }
        .log-header { 
            padding: 6px 14px; background: #eaeeef; font-size: 11px; font-weight: bold; color: #555555; 
            display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #dcdfe3;
        }
        .btn-clear { background: none; border: none; color: #707888; cursor: pointer; font-size: 11px; text-decoration: underline; }
        .btn-clear:hover { color: #333333; }
        #log-box { padding: 10px 14px; overflow-y: auto; flex: 1; font-size: 11px; line-height: 1.6; background: #ffffff; }
        .log-item { margin-bottom: 6px; border-bottom: 1px dotted #e0e0e0; padding-bottom: 4px; }
        .log-time { color: #888888; margin-right: 6px; }
        .log-success { color: #2e7d32; font-weight: bold; }
        .log-error { color: #c62828; font-weight: bold; }
        .log-data { color: #37474f; margin-top: 2px; margin-left: 12px; font-size: 11px; background: #f5f5f5; padding: 4px 6px; border-radius: 3px; overflow-x: auto; }
        
        .leaflet-popup-content { font-size: 13px; }
    </style>
</head>
<body>

<header>
    <div class="title-group">
        <span class="logo-badge">DEBUG / DEMO</span>
        <h1>SafeWay Master Console</h1>
    </div>
    <div class="server-status">
        Base URL: http://localhost:8000
    </div>
</header>

<div class="main-container">
    <!-- マップ領域 -->
    <div id="map-container">
        <div class="map-overlay-info">
            マップ上で任意の地点をクリックすると、選択座標として登録されます。
        </div>
        <div id="map"></div>
    </div>

    <!-- コンソール領域 -->
    <div class="sidebar">
        <!-- タブ切替 -->
        <div class="tabs">
            <button class="tab-btn active-crime" onclick="switchTab('crime')">POST /api/crime-reports</button>
            <button class="tab-btn" onclick="switchTab('detect')">POST /api/detections/debug</button>
        </div>

        <div class="form-content">
            <div class="field-group">
                <label>選択中のターゲット座標 <span class="hint">地図クリックで更新</span></label>
                <div class="coords-box">
                    <input type="text" id="lat-display" readonly placeholder="Lat" />
                    <span>,</span>
                    <input type="text" id="lng-display" readonly placeholder="Lng" />
                </div>
            </div>

            <!-- タブ1: 危険情報 (Crime Report) -->
            <div id="pane-crime" class="tab-pane active">
                <div class="field-group">
                    <label>事象タイプ (event_type)</label>
                    <select id="crime-type" onchange="updateDefaultDescription()">
                        <option value="bear">bear (クマ出没)</option>
                        <option value="wildlife">wildlife (その他の野生動物)</option>
                        <option value="suspicious_person">suspicious_person (不審者・犯罪兆候)</option>
                        <option value="crime_violent">crime_violent (凶悪犯罪)</option>
                    </select>
                </div>

                <div class="field-group">
                    <label>詳細テキスト (description)</label>
                    <textarea id="crime-desc">【頭数】1.0 【状況】干俣川から県道を渡って山の方向へ走って行った</textarea>
                </div>

                <div class="field-group">
                    <label>発生時刻 (occurred_at)</label>
                    <input type="text" value="送信時のサーバー現在時刻(UTC)が自動で割り振られます" disabled />
                </div>

                <button class="btn-submit btn-crime" onclick="submitCrimeReport()">
                    POST /api/crime-reports を実行
                </button>
            </div>

            <!-- タブ2: 物体検出シミュレータ (Detection Debug) -->
            <div id="pane-detect" class="tab-pane">
                <div class="field-group">
                    <label>検出ラベル (label)</label>
                    <select id="detect-label">
                        <option value="streetlight">streetlight (街灯 / 安全スコア加点)</option>
                        <option value="sidewalk">sidewalk (歩道 / 安全スコア加点)</option>
                    </select>
                </div>

                <div class="field-group">
                    <label>反映仕様について</label>
                    <div class="info-box">
                        画像アップロードやカメラ方位角による三角測量を介さず、クリックした座標をそのまま高精度(high)な対象物座標として安全マップ(safety_points)および道路ハザードスコアに直接反映させます。
                    </div>
                </div>

                <button class="btn-submit btn-detect" onclick="submitDetection()">
                    POST /api/detections/debug を実行
                </button>
            </div>
        </div>

        <!-- 実行ログ・レスポンス確認領域 -->
        <div class="log-section">
            <div class="log-header">
                <span>Execution Logs / API Responses</span>
                <button class="btn-clear" onclick="clearLog()">Clear</button>
            </div>
            <div id="log-box">
                <div class="log-item"><span class="log-time">[System]</span> Ready. Click map to set GPS targets and execute API requests.</div>
            </div>
        </div>
    </div>
</div>

<script>
    // デフォルト座標
    let selectedLat = 37.9120;
    let selectedLng = 139.0590;
    let marker = null;

    // Leaflet初期化 (標準OpenStreetMap)
    const map = L.map('map').setView([selectedLat, selectedLng], 15);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; OpenStreetMap contributors',
        maxZoom: 19
    }).addTo(map);

    marker = L.marker([selectedLat, selectedLng]).addTo(map);
    marker.bindPopup("現在の指定座標").openPopup();
    updateDisplay(selectedLat, selectedLng);

    map.on('click', function(e) {
        selectedLat = parseFloat(e.latlng.lat.toFixed(6));
        selectedLng = parseFloat(e.latlng.lng.toFixed(6));
        
        if (marker) {
            marker.setLatLng(e.latlng);
        } else {
            marker = L.marker(e.latlng).addTo(map);
        }
        marker.bindPopup(`選択位置: ${selectedLat}, ${selectedLng}`).openPopup();
        updateDisplay(selectedLat, selectedLng);
    });

    function updateDisplay(lat, lng) {
        document.getElementById('lat-display').value = lat;
        document.getElementById('lng-display').value = lng;
    }

    function switchTab(mode) {
        const btns = document.querySelectorAll('.tab-btn');
        const crimePane = document.getElementById('pane-crime');
        const detectPane = document.getElementById('pane-detect');

        if (mode === 'crime') {
            btns[0].className = 'tab-btn active-crime';
            btns[1].className = 'tab-btn';
            crimePane.className = 'tab-pane active';
            detectPane.className = 'tab-pane';
        } else {
            btns[0].className = 'tab-btn';
            btns[1].className = 'tab-btn active-detect';
            crimePane.className = 'tab-pane';
            detectPane.className = 'tab-pane active';
        }
    }

    function updateDefaultDescription() {
        const type = document.getElementById('crime-type').value;
        const descBox = document.getElementById('crime-desc');
        
        if (type === 'bear') {
            descBox.value = "【頭数】1.0 【状況】干俣川から県道を渡って山の方向へ走って行った";
        } else if (type === 'wildlife') {
            descBox.value = "【野生動物】イノシシの成獣1頭が路上横断、裏路地の方へ逃走";
        } else if (type === 'suspicious_person') {
            descBox.value = "【不審者】身元の分からない人物が辺りを伺いながら不審な行動を取っている";
        } else if (type === 'crime_violent') {
            descBox.value = "【凶悪犯罪】路上にて暴力事態発生の通報あり。直ちに迂回徹底のこと";
        }
    }

    function getTimeStr() {
        const d = new Date();
        return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}:${d.getSeconds().toString().padStart(2, '0')}`;
    }

    function addLog(message, isSuccess = true, data = null) {
        const box = document.getElementById('log-box');
        const time = getTimeStr();
        const statusClass = isSuccess ? 'log-success' : 'log-error';
        const symbol = isSuccess ? 'INFO:' : 'ERROR:';
        
        let html = `<div class="log-item">
            <span class="log-time">[${time}]</span>
            <span class="${statusClass}">${symbol} ${message}</span>`;
            
        if (data) {
            html += `<div class="log-data">${JSON.stringify(data, null, 2)}</div>`;
        }
        html += `</div>`;
        
        box.innerHTML = html + box.innerHTML;
    }

    function clearLog() {
        document.getElementById('log-box').innerHTML = `<div class="log-item"><span class="log-time">[System]</span> Logs cleared.</div>`;
    }

    async function submitCrimeReport() {
        const type = document.getElementById('crime-type').value;
        const desc = document.getElementById('crime-desc').value;

        const payload = {
            event_type: type,
            description: desc,
            lat: selectedLat,
            lng: selectedLng
        };

        addLog(`Requesting POST /api/crime-reports (${type})...`, true);

        try {
            const response = await fetch('/api/crime-reports', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            if (response.ok) {
                const data = await response.json();
                addLog(`Success: Created Crime Report ID #${data.id}`, true, data);
                marker.bindPopup(`<b>Report Added #${data.id}</b><br>Type: ${type}`).openPopup();
            } else {
                const err = await response.text();
                addLog(`HTTP Error ${response.status}: ${err}`, false);
            }
        } catch (error) {
            addLog(`Network Error: ${error.message}`, false);
        }
    }

    async function submitDetection() {
        const label = document.getElementById('detect-label').value;

        const payload = {
            label: label,
            lat: selectedLat,
            lng: selectedLng,
            confidence: 0.99
        };

        addLog(`Requesting POST /api/detections/debug (${label})...`, true);

        try {
            const response = await fetch('/api/detections/debug', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            if (response.ok) {
                const data = await response.json();
                addLog(`Success: Detection Applied ID #${data.id}`, true, data);
                marker.bindPopup(`<b>Detection Applied #${data.id}</b><br>Label: ${label}<br>Score Mod: ${data.score_modifier}`).openPopup();
            } else {
                const err = await response.text();
                addLog(`HTTP Error ${response.status}: ${err}`, false);
            }
        } catch (error) {
            addLog(`Network Error: ${error.message}`, false);
        }
    }
</script>
</body>
</html>
"""
