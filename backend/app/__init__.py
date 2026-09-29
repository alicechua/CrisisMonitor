# backend/app.py
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

from .dto import TweetInput, PredictionOutput

import os
import httpx
import re
from uuid import uuid4
from pymongo import MongoClient
from datetime import datetime, timezone
from typing import Any, Dict

MODEL_URL = f"http://{os.getenv('MODEL_SERVICE_HOST','model-svc')}:{os.getenv('MODEL_SERVICE_PORT','80')}"
MONGO_URI = os.getenv("MONGO_URI", "mongodb://root:example@mongodb-0.mongodb-svc.mlapp.svc.cluster.local:27017/?authSource=admin")
DB_NAME = os.getenv("MONGO_DB", "mlapp")

app = FastAPI()

mongo_client = MongoClient(MONGO_URI)
db = mongo_client[DB_NAME]
events = db["events"]


# allowed origins (frontend domains)
origins = [
    "http://localhost:3000",     # local dev (React/Vite/Next.js)
    "http://localhost:80", 
    "https://disaster-classification-mscac.netlify.app",  # deployed frontend
    "https://crisismonitor-frontend-alice.azurewebsites.net",  # deployed frontend (Azure)
    "http://32.199.57.44",       # deployed frontend (AWS EC2)
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,            # List of allowed origins
    allow_credentials=True,
    allow_methods=["*"],              # Allow all HTTP methods
    allow_headers=["*"],              # Allow all headers
)


def parse_model_response(data: Dict[str, Any]) -> tuple[bool, float]:
    """
    Expected form: {"pred": "disaster", "probs": "P(not disaster)=0.412, P(disaster)=0.588"}
    Returns: (is_real_disaster: bool, disaster_probability: float)
    """

    probs_field = data.get("probs") or data.get("probs_str") or data.get("probabilities")
    if isinstance(probs_field, str):
        # pattern P(disaster)= <float>
        m = re.search(r"P\(\s*disaster\s*\)\s*[:=]\s*([0-9]*\.?[0-9]+)", probs_field, re.IGNORECASE)
        if m:
            prob = float(m.group(1))
            return (prob >= 0.5), prob
        # more permissive: find last float after 'disaster'
        m2 = re.search(r"disaster[^0-9\-+]*([0-9]*\.?[0-9]+)", probs_field, re.IGNORECASE)
        if m2:
            prob = float(m2.group(1))
            return (prob >= 0.5), prob

    # fallback
    return None, 0.0


@app.get("/")
def home():
    return {"message": "Hello FastAPI"}


@app.get("/health")
def health():
    return {"status": "ok"}



@app.post("/predict-tweet")
async def classify(payload: TweetInput):
    async with httpx.AsyncClient(timeout=20) as client:
        try:
            r = await client.post(f"{MODEL_URL}/predict", json={"text": payload.text})
            r.raise_for_status()
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"Model service error: {e}")

    data = r.json()
    # parse model response into boolean + probability
    is_real, prob = parse_model_response(data)

    # build document to insert
    doc = {
        "id": str(uuid4()),
        "cleaned_tweet": (payload.text or "").strip(),
        "is_real_disaster": bool(is_real),
        "disaster_probability": float(prob),
        "evaluated_at": datetime.now(timezone.utc),
    }

    try:
        events.insert_one(doc)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"DB insert error: {e}")

    return PredictionOutput(**doc)



@app.get("/events")
def get_events_between(
    start: str = Query(..., description="ISO 8601 start timestamp, inclusive. Example: 2025-11-01T00:00:00Z"),
    end: str = Query(..., description="ISO 8601 end timestamp, inclusive. Example: 2025-11-03T23:59:59Z"),
    limit: int = Query(100, ge=1, le=10000, description="Maximum number of events to return (1-10000). Default 100")
):
    """
    Return events between `start` and `end` (both ISO8601). Results are sorted newest -> oldest.
    Example: /events?start=2025-11-01T00:00:00Z&end=2025-11-03T23:59:59Z&limit=50 
    """
    try:
        # normalize 'Z' to '+00:00' so fromisoformat can parse
        start_dt = datetime.fromisoformat(start.replace("Z", "+00:00"))
        if start_dt.tzinfo is None:
            start_dt = start_dt.replace(tzinfo=timezone.utc)

        end_dt = datetime.fromisoformat(end.replace("Z", "+00:00"))
        if end_dt.tzinfo is None:
            end_dt = end_dt.replace(tzinfo=timezone.utc)

        if end_dt < start_dt:
            raise HTTPException(status_code=400, detail="`end` must be the same or after `start`.")

        # Build query for MongoDB
        query = {"evaluated_at": {"$gte": start_dt, "$lte": end_dt}}

        cursor = events.find(query).sort("evaluated_at", -1).limit(limit)
        docs = list(cursor)

        out = []
        for doc in docs:
            doc["_id"] = str(doc["_id"])
            ev = doc.get("evaluated_at")
            if isinstance(ev, datetime):
                doc["evaluated_at"] = ev.astimezone(timezone.utc).isoformat()
            else:
                doc["evaluated_at"] = str(ev)
            out.append(doc)

        return JSONResponse(content=out)

    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid timestamp format. Use ISO 8601.")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))