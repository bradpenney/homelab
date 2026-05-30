#!/usr/bin/env python3
"""Sync Garmin Connect activities to Wanderer trail journal."""

import json
import sys
from datetime import date
from pathlib import Path

import garminconnect
import requests

HOMELAB_DIR = Path(__file__).parent


def load_env():
    env = {}
    for line in (HOMELAB_DIR / ".env").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        env[k.strip()] = v
    return env


ENV = load_env()

GARMIN_EMAIL = ENV["GARMIN_EMAIL"]
GARMIN_PASSWORD = ENV["GARMIN_PASSWORD"]
GARMIN_TOKEN_DIR = HOMELAB_DIR / ".garmin-tokens"

WANDERER_URL = "http://localhost:8090"
WANDERER_EMAIL = ENV["WANDERER_EMAIL"]
WANDERER_PASSWORD = ENV["WANDERER_PASSWORD"]

STATE_FILE = HOMELAB_DIR / "garmin-sync-state.json"

_start = ENV.get("GARMIN_SYNC_START_DATE", "")
START_DATE = date.fromisoformat(_start) if _start else None

# Garmin activityType.typeKey → Wanderer category name
# Add your SxS custom type key here once you see it logged as "unmapped"
CATEGORY_MAP = {
    "walking": "Walking",
    "running": "Walking",
    "trail_running": "Hiking",
    "hiking": "Hiking",
    "cycling": "Biking",
    "mountain_biking": "Biking",
    "gravel_cycling": "Biking",
    "swimming": "Workout",
    "lap_swimming": "Workout",
    "strength_training": "Workout",
    "yoga": "Workout",
    "skiing": "Skiing",
    "backcountry_skiing": "Skiing",
    "kayaking": "Canoeing",
    "paddling": "Canoeing",
    "rock_climbing": "Climbing",
}


def load_state():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"synced_ids": []}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def garmin_login():
    client = garminconnect.Garmin(GARMIN_EMAIL, GARMIN_PASSWORD)
    GARMIN_TOKEN_DIR.mkdir(exist_ok=True)
    try:
        client.login(str(GARMIN_TOKEN_DIR))
        print("Garmin: loaded cached tokens")
    except Exception:
        print("Garmin: no cached tokens, authenticating (MFA prompt may appear)...")
        client.login()
        client.garth.dump(str(GARMIN_TOKEN_DIR))
        print("Garmin: tokens cached for future runs")
    return client


def wanderer_auth():
    if not WANDERER_PASSWORD:
        raise RuntimeError(
            "WANDERER_PASSWORD not set — create your account at "
            "https://trails.bradpenney.io then set WANDERER_EMAIL and WANDERER_PASSWORD in .env"
        )
    r = requests.post(
        f"{WANDERER_URL}/api/collections/users/auth-with-password",
        json={"identity": WANDERER_EMAIL, "password": WANDERER_PASSWORD},
        timeout=10,
    )
    r.raise_for_status()
    data = r.json()
    return data["token"], data["record"]["id"]


def get_actor_id(token, user_id):
    r = requests.get(
        f"{WANDERER_URL}/api/collections/activitypub_actors/records",
        headers={"Authorization": token},
        params={"filter": f'user="{user_id}"'},
        timeout=10,
    )
    r.raise_for_status()
    items = r.json().get("items", [])
    if not items:
        raise RuntimeError(f"No Wanderer actor found for user {user_id}")
    return items[0]["id"]


def get_category_id(token, name):
    if not name:
        return ""
    r = requests.get(
        f"{WANDERER_URL}/api/collections/categories/records",
        headers={"Authorization": token},
        params={"filter": f'name="{name}"'},
        timeout=10,
    )
    r.raise_for_status()
    items = r.json().get("items", [])
    return items[0]["id"] if items else ""


def create_trail(token, actor_id, activity, gpx_bytes, category_id):
    name = activity.get("activityName") or "Untitled"
    data = {
        "name": name,
        "public": "false",
        "distance": str(round(activity.get("distance") or 0)),
        "elevation_gain": str(round(activity.get("elevationGain") or 0)),
        "duration": str(int(activity.get("duration") or 0)),
        "date": activity.get("startTimeLocal", ""),
        "lat": str(activity.get("startLatitude") or 0),
        "lon": str(activity.get("startLongitude") or 0),
        "difficulty": "easy",
        "author": actor_id,
    }
    if category_id:
        data["category"] = category_id

    files = None
    if gpx_bytes:
        files = {"gpx": (f"garmin_{activity['activityId']}.gpx", gpx_bytes, "application/gpx+xml")}

    r = requests.post(
        f"{WANDERER_URL}/api/collections/trails/records",
        headers={"Authorization": token},
        data=data,
        files=files,
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["id"]


def main():
    state = load_state()
    synced_ids = set(state["synced_ids"])

    print("Connecting to Garmin Connect...")
    garmin = garmin_login()

    print("Fetching recent activities...")
    activities = garmin.get_activities(0, 50)

    new_activities = [
        a for a in activities
        if str(a["activityId"]) not in synced_ids
        and (START_DATE is None or date.fromisoformat(a["startTimeLocal"][:10]) >= START_DATE)
    ]
    if not new_activities:
        print("No new activities to sync.")
        return

    print(f"{len(new_activities)} new activity/activities to sync.")

    print("Connecting to Wanderer...")
    token, user_id = wanderer_auth()
    actor_id = get_actor_id(token, user_id)

    category_cache = {}

    for activity in reversed(new_activities):  # oldest first
        garmin_id = str(activity["activityId"])
        name = activity.get("activityName") or "Untitled"
        activity_type = (activity.get("activityType") or {}).get("typeKey", "")

        print(f"  Syncing: {name!r} [{activity_type}]")

        category_name = CATEGORY_MAP.get(activity_type, "")
        if activity_type and not category_name:
            print(f"    Note: unmapped type '{activity_type}' — add it to CATEGORY_MAP if needed")
        if category_name not in category_cache:
            category_cache[category_name] = get_category_id(token, category_name)
        category_id = category_cache[category_name]

        try:
            gpx_bytes = garmin.download_activity(
                activity["activityId"],
                dl_fmt=garmin.ActivityDownloadFormat.GPX,
            )
        except Exception as e:
            print(f"    Warning: GPX download failed: {e}")
            gpx_bytes = None

        try:
            trail_id = create_trail(token, actor_id, activity, gpx_bytes, category_id)
            synced_ids.add(garmin_id)
            print(f"    → Trail created: {trail_id}")
        except Exception as e:
            print(f"    Error creating trail: {e}", file=sys.stderr)
            continue

    state["synced_ids"] = list(synced_ids)
    save_state(state)
    print("Done.")


if __name__ == "__main__":
    main()
