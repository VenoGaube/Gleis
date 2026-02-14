#!/usr/bin/env python3
"""
Scrape public OeBB web assets for API endpoints and generate a Postman collection.

Outputs:
- scripts/generated/oebb_api_endpoints.json
- scripts/generated/oebb_api.postman_collection.json
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import urllib.parse
import urllib.request
from datetime import datetime, timezone

SHOP_BASE = "https://shop.oebbtickets.at"
FAHRPLAN_BASE = "https://fahrplan.oebb.at"
WEB_MAIN_JS = f"{SHOP_BASE}/static/web.main.js"

# Core endpoint extraction regexes.
SHOP_API_RE = re.compile(r"api/[A-Za-z0-9_./{}\-]+")
FAHRPLAN_BIN_RE = re.compile(r"(?:https://fahrplan\.oebb\.at)?/bin/[A-Za-z0-9_.\-]+\.exe/[a-z]+")

# Placeholders used in bundle paths.
PLACEHOLDER_RE = re.compile(r"\{(\d+)\}")

SSL_CONTEXT = ssl._create_unverified_context()


def fetch_text(url: str, timeout: int = 30) -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; Gleis-OeBB-API-Scraper/1.0)",
            "Accept": "text/html,application/javascript,*/*",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout, context=SSL_CONTEXT) as response:
        data = response.read()
        content_type = response.headers.get("Content-Type", "")
        encoding = "utf-8"
        if "charset=" in content_type:
            encoding = content_type.split("charset=")[-1].split(";")[0].strip()
        try:
            return data.decode(encoding, errors="replace")
        except LookupError:
            return data.decode("utf-8", errors="replace")


def normalize_shop_endpoint(value: str) -> str | None:
    cleaned = value.strip().strip("\"'`")
    if not cleaned:
        return None

    cleaned = cleaned.replace("api//", "api/")
    if not cleaned.startswith("api/"):
        return None

    cleaned = re.sub(r"[^A-Za-z0-9_./{}\-].*$", "", cleaned)
    cleaned = cleaned.strip()
    if not cleaned:
        return None

    return f"/{cleaned}"


def normalize_fahrplan_endpoint(value: str) -> str | None:
    cleaned = value.strip().strip("\"'`")
    if cleaned.startswith("https://"):
        cleaned = urllib.parse.urlparse(cleaned).path
    cleaned = cleaned.split("?", 1)[0]
    cleaned = cleaned.strip()
    if not cleaned.startswith("/bin/"):
        return None
    return cleaned


def scrape_shop_api_endpoints() -> list[str]:
    js = fetch_text(WEB_MAIN_JS)
    endpoints = set()
    for match in SHOP_API_RE.findall(js):
        endpoint = normalize_shop_endpoint(match)
        if endpoint:
            endpoints.add(endpoint)
    return sorted(endpoints)


def scrape_fahrplan_endpoints() -> list[str]:
    seed_pages = [
        f"{FAHRPLAN_BASE}/bin/query.exe/dn",
        f"{FAHRPLAN_BASE}/bin/stboard.exe/dn",
        f"{FAHRPLAN_BASE}/bin/trainsearch.exe/dn",
        f"{FAHRPLAN_BASE}/bin/traininfo.exe/dn",
    ]

    endpoints = set()
    for page in seed_pages:
        html = fetch_text(page)
        for match in FAHRPLAN_BIN_RE.findall(html):
            endpoint = normalize_fahrplan_endpoint(match)
            if endpoint:
                endpoints.add(endpoint)

    # Known variants observed in query/stboard page links.
    endpoints.update(
        {
            "/gate",
            "/bin/query.exe/dn",
            "/bin/query.exe/dny",
            "/bin/query.exe/en",
            "/bin/stboard.exe/dn",
            "/bin/stboard.exe/dny",
            "/bin/stboard.exe/en",
            "/bin/trainsearch.exe/dn",
            "/bin/trainsearch.exe/en",
            "/bin/traininfo.exe/dn",
            "/bin/ajax-getstop.exe/dn",
            "/bin/profile.exe/dn",
            "/bin/help.exe/dn",
        }
    )

    return sorted(endpoints)


def to_postman_path(path: str) -> str:
    # Convert /api/order/{0}/something -> /api/order/:p0/something
    return PLACEHOLDER_RE.sub(lambda m: f":p{m.group(1)}", path)


def shop_headers(include_auth: bool = True) -> list[dict[str, str]]:
    headers = [{"key": "Accept", "value": "application/json", "type": "text"}]
    if include_auth:
        headers.extend(
            [
                {"key": "Channel", "value": "{{channel}}", "type": "text"},
                {"key": "AccessToken", "value": "{{access_token}}", "type": "text"},
                {"key": "SessionId", "value": "{{session_id}}", "type": "text"},
                {"key": "x-ts-supportid", "value": "WEB_{{support_id}}", "type": "text"},
                {"key": "Cookie", "value": "ts-cookie={{ts_cookie}}", "type": "text"},
            ]
        )
    return headers


def postman_request(
    *,
    name: str,
    method: str,
    raw_url: str,
    headers: list[dict[str, str]] | None = None,
    body: dict | None = None,
    event: list[dict] | None = None,
    description: str = "",
) -> dict:
    req: dict = {
        "name": name,
        "request": {
            "method": method,
            "header": headers or [],
            "url": raw_url,
            "description": description,
        },
    }
    if body is not None:
        req["request"]["body"] = body
    if event is not None:
        req["event"] = event
    return req


def build_postman_collection(shop_endpoints: list[str], fahrplan_endpoints: list[str]) -> dict:
    now = datetime.now(timezone.utc).isoformat()

    known_items = [
        postman_request(
            name="Auth init (GET /api/domain/v3/init)",
            method="GET",
            raw_url="{{shop_base}}/api/domain/v3/init?userId={{user_id}}",
            headers=[{"key": "Channel", "value": "inet", "type": "text"}],
            event=[
                {
                    "listen": "test",
                    "script": {
                        "type": "text/javascript",
                        "exec": [
                            "let data = {};",
                            "try { data = pm.response.json(); } catch (e) {}",
                            "if (data.accessToken) pm.collectionVariables.set('access_token', data.accessToken);",
                            "if (data.sessionId) pm.collectionVariables.set('session_id', data.sessionId);",
                            "if (data.supportId) pm.collectionVariables.set('support_id', data.supportId);",
                            "pm.collectionVariables.set('channel', data.channel || 'inet');",
                            "const setCookie = pm.response.headers.get('set-cookie') || '';",
                            "const match = setCookie.match(/ts-cookie=([^;]+)/);",
                            "if (match && match[1]) pm.collectionVariables.set('ts_cookie', match[1]);",
                        ],
                    },
                }
            ],
            description="Initialize an anonymous session and collect AccessToken/SessionId/supportId headers.",
        ),
        postman_request(
            name="Stations by name (Graz)",
            method="GET",
            raw_url="{{shop_base}}/api/hafas/v1/stations?count=20&name=Graz",
            headers=shop_headers(True),
            description="Location query by station name.",
        ),
        postman_request(
            name="Nearby stations (Graz coords)",
            method="GET",
            raw_url="{{shop_base}}/api/hafas/v1/stations?count=20&latitude={{graz_lat_micro}}&longitude={{graz_lon_micro}}",
            headers=shop_headers(True),
            description="Location query by coordinates; Graz defaults are prefilled in collection variables.",
        ),
        postman_request(
            name="Timetable (Graz Hbf -> Wien Hbf)",
            method="POST",
            raw_url="{{shop_base}}/api/hafas/v4/timetable",
            headers=shop_headers(True)
            + [{"key": "Content-Type", "value": "application/json", "type": "text"}],
            body={
                "mode": "raw",
                "raw": json.dumps(
                    {
                        "reverse": False,
                        "datetimeDeparture": "{{departure_iso}}",
                        "filter": {
                            "regionaltrains": False,
                            "direct": False,
                            "changeTime": False,
                            "wheelchair": False,
                            "bikes": False,
                            "trains": False,
                            "motorail": False,
                            "droppedConnections": False,
                        },
                        "passengers": [
                            {
                                "type": "ADULT",
                                "id": 1514028726,
                                "me": False,
                                "remembered": False,
                                "challengedFlags": {
                                    "hasHandicappedPass": False,
                                    "hasAssistanceDog": False,
                                    "hasWheelchair": False,
                                    "hasAttendant": False,
                                },
                                "relations": [],
                                "cards": [],
                                "birthdateChangeable": True,
                                "birthdateDeletable": True,
                                "nameChangeable": True,
                                "passengerDeletable": True,
                            }
                        ],
                        "count": 10,
                        "debugFilter": {
                            "noAggregationFilter": False,
                            "noEqclassFilter": False,
                            "noNrtpathFilter": False,
                            "noPaymentFilter": False,
                            "useTripartFilter": False,
                            "noVbxFilter": False,
                            "noCategoriesFilter": False,
                        },
                        "from": {
                            "latitude": 47072660,
                            "longitude": 15419310,
                            "name": "Graz Hbf",
                            "number": 8100173,
                        },
                        "to": {
                            "latitude": 48208980,
                            "longitude": 16372100,
                            "name": "Wien Hbf",
                            "number": 8103000,
                        },
                        "timeout": {},
                    },
                    indent=2,
                ),
                "options": {"raw": {"language": "json"}},
            },
            description="Time-based query using payload structure from OebbAPIClient.swift.",
        ),
        postman_request(
            name="Station board (fahrplan, departures)",
            method="GET",
            raw_url="{{fahrplan_base}}/bin/stboard.exe/dn?L=vs_scotty.vs_liveticker&evaId={{graz_hbf_evaid}}&boardType=dep&time={{board_time}}&productsFilter=1111111111111111&additionalTime=0&maxJourneys=50&outputMode=tickerDataOnly&start=yes&selectDate=period&dateBegin={{board_date}}&dateEnd={{board_date}}",
            description="Legacy station board endpoint used by client (returns ticker-style payload).",
        ),
        postman_request(
            name="Gate LocGeoPos (nearby stops from current/Graz position)",
            method="POST",
            raw_url="{{fahrplan_base}}/gate?rnd={{gate_rnd}}",
            headers=[
                {"key": "Accept", "value": "application/json", "type": "text"},
                {"key": "Content-Type", "value": "application/json", "type": "text"},
            ],
            body={
                "mode": "raw",
                "raw": json.dumps(
                    {
                        "id": "{{gate_req_id}}",
                        "ver": "1.88",
                        "lang": "deu",
                        "auth": {"type": "AID", "aid": "{{gate_aid}}"},
                        "client": {
                            "id": "OEBB",
                            "type": "WEB",
                            "name": "webapp",
                            "l": "vs_webapp",
                            "v": 21901,
                            "pos": {"x": "{{gate_pos_x}}", "y": "{{gate_pos_y}}", "acc": "{{gate_pos_acc}}"},
                        },
                        "formatted": False,
                        "ext": "OEBB.14",
                        "svcReqL": [
                            {
                                "meth": "LocGeoPos",
                                "req": {
                                    "centerCrd": {"y": "{{gate_pos_y}}", "x": "{{gate_pos_x}}"},
                                    "getPOIs": False,
                                    "getStops": True,
                                    "maxLoc": 7,
                                },
                            }
                        ],
                    },
                    indent=2,
                ),
                "options": {"raw": {"language": "json"}},
            },
            event=[
                {
                    "listen": "prerequest",
                    "script": {
                        "type": "text/javascript",
                        "exec": ["pm.collectionVariables.set('gate_rnd', String(Date.now()));"],
                    },
                }
            ],
            description="Endpoint used by fahrplan webapp after location consent to fetch nearby stops.",
        ),
    ]

    discovered_shop_items = []
    for endpoint in shop_endpoints:
        path = to_postman_path(endpoint)
        method = "POST" if endpoint == "/api/hafas/v4/timetable" else "GET"
        headers = shop_headers(True)
        body = None
        if method == "POST":
            headers = headers + [{"key": "Content-Type", "value": "application/json", "type": "text"}]
            body = {"mode": "raw", "raw": "{}", "options": {"raw": {"language": "json"}}}

        discovered_shop_items.append(
            postman_request(
                name=f"{method} {endpoint}",
                method=method,
                raw_url=f"{{{{shop_base}}}}{path}",
                headers=headers,
                body=body,
                description="Discovered from web.main.js. Method defaults to GET unless known otherwise.",
            )
        )

    discovered_fahrplan_items = []
    for endpoint in fahrplan_endpoints:
        discovered_fahrplan_items.append(
            postman_request(
                name=f"GET {endpoint}",
                method="GET",
                raw_url=f"{{{{fahrplan_base}}}}{endpoint}",
                description="Discovered from fahrplan HTML pages; add query params as needed.",
            )
        )

    collection = {
        "info": {
            "name": "OeBB API Scraped Collection",
            "_postman_id": "dd1f5bf8-12ce-4974-b17f-5217f0dce1f4",
            "description": (
                "Generated by scripts/scrape_oebb_api.py from shop.oebbtickets.at and fahrplan.oebb.at. "
                f"Generated at {now}."
            ),
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        "variable": [
            {"key": "shop_base", "value": SHOP_BASE},
            {"key": "fahrplan_base", "value": FAHRPLAN_BASE},
            {"key": "channel", "value": "inet"},
            {"key": "user_id", "value": "anonym-abc12345-defg-hi"},
            {"key": "access_token", "value": ""},
            {"key": "session_id", "value": ""},
            {"key": "support_id", "value": ""},
            {"key": "ts_cookie", "value": ""},
            {"key": "graz_lat_micro", "value": "47070683"},
            {"key": "graz_lon_micro", "value": "15439497"},
            {"key": "graz_hbf_evaid", "value": "8100173"},
            {"key": "board_time", "value": "12:00"},
            {"key": "board_date", "value": "14.02.2026"},
            {"key": "departure_iso", "value": "2026-02-14T12:00:00.000"},
            {"key": "gate_rnd", "value": "1771059310844"},
            {"key": "gate_req_id", "value": "dx2cgxg6m8rbhgwg"},
            {"key": "gate_aid", "value": "5vHavmuWPWIfetEe"},
            {"key": "gate_pos_x", "value": "15439497"},
            {"key": "gate_pos_y", "value": "47070683"},
            {"key": "gate_pos_acc", "value": "35"},
        ],
        "item": [
            {"name": "Known Core Requests", "item": known_items},
            {"name": f"Discovered shop.oebbtickets.at endpoints ({len(discovered_shop_items)})", "item": discovered_shop_items},
            {"name": f"Discovered fahrplan.oebb.at endpoints ({len(discovered_fahrplan_items)})", "item": discovered_fahrplan_items},
        ],
    }

    return collection


def build_inventory(shop_endpoints: list[str], fahrplan_endpoints: list[str]) -> dict:
    return {
        "source": {
            "shop": WEB_MAIN_JS,
            "fahrplan_pages": [
                f"{FAHRPLAN_BASE}/bin/query.exe/dn",
                f"{FAHRPLAN_BASE}/bin/stboard.exe/dn",
                f"{FAHRPLAN_BASE}/bin/trainsearch.exe/dn",
                f"{FAHRPLAN_BASE}/bin/traininfo.exe/dn",
            ],
        },
        "counts": {
            "shop_endpoints": len(shop_endpoints),
            "fahrplan_endpoints": len(fahrplan_endpoints),
            "total": len(shop_endpoints) + len(fahrplan_endpoints),
        },
        "shop_endpoints": shop_endpoints,
        "fahrplan_endpoints": fahrplan_endpoints,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Scrape OeBB endpoints and build Postman collection")
    parser.add_argument(
        "--inventory-out",
        default="scripts/generated/oebb_api_endpoints.json",
        help="Path to endpoint inventory JSON output",
    )
    parser.add_argument(
        "--postman-out",
        default="scripts/generated/oebb_api.postman_collection.json",
        help="Path to Postman collection JSON output",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    shop_endpoints = scrape_shop_api_endpoints()
    fahrplan_endpoints = scrape_fahrplan_endpoints()

    inventory = build_inventory(shop_endpoints, fahrplan_endpoints)
    collection = build_postman_collection(shop_endpoints, fahrplan_endpoints)

    with open(args.inventory_out, "w", encoding="utf-8") as f:
        json.dump(inventory, f, indent=2, ensure_ascii=False)
        f.write("\n")

    with open(args.postman_out, "w", encoding="utf-8") as f:
        json.dump(collection, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(
        f"Wrote {args.inventory_out} ({inventory['counts']['total']} endpoints) and {args.postman_out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
