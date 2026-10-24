#!/usr/bin/env python3
"""Print an Open ASR Leaderboard table as CSV, read from the leaderboard's Space.

The results datasets behind it (hf-audio/open-asr-leaderboard-results,
hf-audio/leaderboard_longform) went private around 2026-10-22, so the tables
come from the Space's Gradio API instead.

  leaderboard.py                       short-form English, every column, proprietary rows included
  leaderboard.py --version 21-10-2026  the same table as it stood in that version
  leaderboard.py --versions            the version ids, newest first
  leaderboard.py --longform            the long-form table
  leaderboard.py --private             the private-data table (scripted, conversational)
"""

import argparse
import csv
import json
import re
import sys
import urllib.request

SPACE = "https://hf-audio-open-asr-leaderboard.hf.space"
TIMEOUT_SECONDS = 60


def fetch_json(url, body=None):
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def call(endpoint, data):
    event_id = fetch_json(f"{SPACE}/gradio_api/call/{endpoint}", {"data": data})["event_id"]
    with urllib.request.urlopen(f"{SPACE}/gradio_api/call/{endpoint}/{event_id}", timeout=TIMEOUT_SECONDS) as response:
        events = response.read().decode().splitlines()
    payload = [line for line in events if line.startswith("data:")][-1][len("data:"):]
    return json.loads(payload)


def endpoint_parameters(endpoint):
    info = fetch_json(f"{SPACE}/gradio_api/info")
    return info["named_endpoints"][f"/{endpoint}"]["parameters"]


def literal_choices(parameter):
    return re.findall(r"'([^']+)'", parameter["python_type"]["type"])


def main_table_columns():
    # The average covers whichever dataset columns are selected, so keep the
    # leaderboard's default datasets and add only the columns that are not
    # datasets (licence, size, encoder...): the ones the dataset picker lacks.
    parameters = {p["parameter_name"]: p for p in endpoint_parameters("_refresh_all_tables")}
    datasets = set(literal_choices(parameters["pareto_datasets"]))
    metadata = [c for c in literal_choices(parameters["selected_columns"]) if c not in datasets]
    return metadata + parameters["selected_columns"]["parameter_default"]


def config_table(elem_id):
    config = fetch_json(f"{SPACE}/config")
    component = next(c for c in config["components"] if c.get("props", {}).get("elem_id") == elem_id)
    return component["props"]["value"]


def strip_link(cell):
    return re.sub(r"<[^>]+>", "", cell) if isinstance(cell, str) else cell


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="latest")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--versions", action="store_true")
    group.add_argument("--longform", action="store_true")
    group.add_argument("--private", action="store_true")
    args = parser.parse_args()

    if args.versions:
        version = next(p for p in endpoint_parameters("_main_table_update") if p["parameter_name"] == "version_id")
        print("\n".join(literal_choices(version)))
        return

    if args.longform:
        table = config_table("longform-table")
    elif args.private:
        table = call("_private_update", [args.version, "", True, "Scripted vs. Conversational"])[0]["value"]
    else:
        show_proprietary, show_llm = True, True
        table = call("_main_table_update", [args.version, "", show_proprietary, show_llm, main_table_columns()])[0]["value"]

    writer = csv.writer(sys.stdout)
    writer.writerow(table["headers"])
    for row in table["data"]:
        writer.writerow([strip_link(cell) for cell in row])


if __name__ == "__main__":
    main()
