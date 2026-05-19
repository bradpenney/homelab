#!/usr/bin/env python3
"""
Two-way sync between Google Calendar and Nextcloud Calendar via CalDAV.
Configuration is read from .env in the same directory.
Google is authoritative for conflicts (both sides changed since last sync).
State is tracked in ~/.local/share/gcal-sync/state.json.
"""

import sys
import json
import pickle
import hashlib
import logging
import urllib.parse
from pathlib import Path
from datetime import datetime, timezone

import caldav
from icalendar import Calendar as iCal
from requests.auth import AuthBase
from google.auth.transport.requests import Request

SCRIPT_DIR = Path(__file__).parent.absolute()
STATE_FILE = Path.home() / '.local' / 'share' / 'gcal-sync' / 'state.json'

# Fields that CalDAV servers overwrite on every PUT — exclude from change detection
_VOLATILE = frozenset({'DTSTAMP', 'LAST-MODIFIED', 'CREATED', 'X-LIC-ERROR'})


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _load_env() -> dict:
    env = {}
    env_file = SCRIPT_DIR / '.env'
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, _, v = line.partition('=')
            env[k.strip()] = v.strip()
    return env


def _require(env: dict, key: str) -> str:
    val = env.get(key, '')
    if not val:
        raise RuntimeError(f"Missing required .env variable: {key}")
    return val


# ---------------------------------------------------------------------------
# Google auth
# ---------------------------------------------------------------------------

class BearerAuth(AuthBase):
    def __init__(self, token: str):
        self._token = token

    def __call__(self, r):
        r.headers['Authorization'] = f'Bearer {self._token}'
        return r


def _get_google_credentials(token_file: str):
    with open(token_file, 'rb') as f:
        creds = pickle.load(f)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        with open(token_file, 'wb') as f:
            pickle.dump(creds, f)
    if not creds.valid:
        raise RuntimeError(
            f"Google credentials invalid. Re-authenticate by running the gcal auth script."
        )
    return creds


# ---------------------------------------------------------------------------
# iCal helpers
# ---------------------------------------------------------------------------

def _parse_vevent(event_data: str):
    cal = iCal.from_ical(event_data)
    for comp in cal.walk():
        if comp.name == 'VEVENT':
            return comp
    return None


def _get_uid(event) -> str:
    vevent = _parse_vevent(event.data)
    return str(vevent.get('UID', '')) if vevent else ''


def _stable_hash(event_data: str) -> str:
    """Hash event content, excluding server-side volatile timestamps."""
    vevent = _parse_vevent(event_data)
    if vevent is None:
        return ''
    parts = [f"{k}={vevent[k]!r}" for k in sorted(vevent.keys()) if k not in _VOLATILE]
    return hashlib.sha256('\n'.join(parts).encode()).hexdigest()


def _build_map(calendar) -> dict[str, tuple]:
    """Return {uid: (event, content_hash)} for all events."""
    result = {}
    for event in calendar.events():
        uid = _get_uid(event)
        if uid:
            result[uid] = (event, _stable_hash(event.data))
    return result


# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

def sync():
    logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s',
                        stream=sys.stdout)
    logger = logging.getLogger(__name__)

    env = _load_env()
    google_email     = _require(env, 'GOOGLE_EMAIL')
    token_file       = _require(env, 'GCAL_TOKEN_FILE')
    nc_domain        = _require(env, 'NEXTCLOUD_DOMAIN')
    nc_username      = _require(env, 'NEXTCLOUD_USERNAME')
    nc_calendar      = _require(env, 'NEXTCLOUD_CALENDAR')
    nc_password      = _require(env, 'BRAD_NEXTCLOUD_PAT')

    encoded_email = urllib.parse.quote(google_email, safe='')
    google_cal_url  = f'https://apidata.googleusercontent.com/caldav/v2/{encoded_email}/events/'
    nextcloud_cal_url = f'https://{nc_domain}/remote.php/dav/calendars/{nc_username}/{nc_calendar}/'

    creds = _get_google_credentials(token_file)

    g_client = caldav.DAVClient(url=google_cal_url, auth=BearerAuth(creds.token))
    n_client = caldav.DAVClient(url=nextcloud_cal_url, username=nc_username, password=nc_password)

    g_cal = g_client.calendar(url=google_cal_url)
    n_cal = n_client.calendar(url=nextcloud_cal_url)

    logger.info("Fetching events...")
    g_map = _build_map(g_cal)
    n_map = _build_map(n_cal)
    logger.info(f"Google: {len(g_map)} events, Nextcloud: {len(n_map)} events")

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    state: dict = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}

    new_state: dict = {}
    created = updated = deleted = errors = 0

    for uid in set(g_map) | set(n_map):
        g_event, g_hash = g_map.get(uid, (None, None))
        n_event, n_hash = n_map.get(uid, (None, None))
        s = state.get(uid, {})
        g_changed = g_hash != s.get('g')
        n_changed = n_hash != s.get('n')

        try:
            if g_event and n_event:
                if g_changed and not n_changed:
                    n_event.data = g_event.data
                    n_event.save()
                    n_event.load()
                    n_hash = _stable_hash(n_event.data)
                    logger.info(f"Updated Nextcloud: {uid[:16]}")
                    updated += 1
                elif n_changed and not g_changed:
                    g_event.data = n_event.data
                    g_event.save()
                    g_event.load()
                    g_hash = _stable_hash(g_event.data)
                    logger.info(f"Updated Google: {uid[:16]}")
                    updated += 1
                elif g_changed and n_changed:
                    # Conflict — Google wins
                    n_event.data = g_event.data
                    n_event.save()
                    n_event.load()
                    n_hash = _stable_hash(n_event.data)
                    logger.warning(f"Conflict (Google wins): {uid[:16]}")
                    updated += 1
                new_state[uid] = {'g': g_hash, 'n': n_hash}

            elif g_event and not n_event:
                if uid in state:
                    g_event.delete()
                    logger.info(f"Deleted from Google: {uid[:16]}")
                    deleted += 1
                else:
                    result = n_cal.add_event(g_event.data)
                    if result:
                        result.load()
                        n_hash = _stable_hash(result.data)
                    logger.info(f"Created in Nextcloud: {uid[:16]}")
                    created += 1
                    new_state[uid] = {'g': g_hash, 'n': n_hash}

            else:  # n_event only
                if uid in state:
                    n_event.delete()
                    logger.info(f"Deleted from Nextcloud: {uid[:16]}")
                    deleted += 1
                else:
                    result = g_cal.add_event(n_event.data)
                    if result:
                        result.load()
                        g_hash = _stable_hash(result.data)
                    logger.info(f"Created in Google: {uid[:16]}")
                    created += 1
                    new_state[uid] = {'g': g_hash, 'n': n_hash}

        except Exception as e:
            logger.warning(f"Skipped {uid[:16]}: {e}")
            errors += 1
            if uid in state:
                new_state[uid] = state[uid]

    STATE_FILE.write_text(json.dumps(new_state))
    logger.info(f"Done: {created} created, {updated} updated, {deleted} deleted, {errors} skipped.")


if __name__ == '__main__':
    sync()
