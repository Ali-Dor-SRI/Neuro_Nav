"""
parse_brainsight.py
-------------------
Parser for Brainsight streamed-info text files (.txt).

Usage
-----
    from parse_brainsight import parse_brainsight

    tables = parse_brainsight("Session 3  Streamed Info.txt")

    df_coil    = tables["Polaris Tool"]
    df_samples = tables["New Sample"]
    df_emg     = tables["New EMG"]

Returns
-------
dict[str, pd.DataFrame]
    Keys are row-type names (see SCHEMAS below).
    Values are DataFrames; absent row types return an empty DataFrame
    with the correct columns.
    "(null)" values are replaced with pd.NA.
    Numeric columns (x, y, z, matrix cells, EMG values) are cast to float.
"""

import re
import pandas as pd
from pathlib import Path
from typing import Union

# ---------------------------------------------------------------------------
# Schema: maps each row-type label to its ordered column names
# ---------------------------------------------------------------------------
SCHEMAS: dict[str, list[str]] = {
    "Polaris Tool": [
        "row_type", "date", "time", "frame_number", "tracker_name",
        "coord_system", "x", "y", "z",
        "m0n0", "m0n1", "m0n2",
        "m1n0", "m1n1", "m1n2",
        "m2n0", "m2n1", "m2n2",
    ],
    "TTL Trigger": [
        "row_type", "date", "time", "trigger_name",
    ],
    "New Sample": [
        "row_type", "date", "time", "sample_name", "index",
        "coord_system", "loc_x", "loc_y", "loc_z",
        "m0n0", "m0n1", "m0n2",
        "m1n0", "m1n1", "m1n2",
        "m2n0", "m2n1", "m2n2",
        "assoc_target",
    ],
    "New EMG": [
        "row_type", "date", "time", "sample_name", "index",
        "emg_peak_to_peak_1", "emg_peak_to_peak_2",
        "emg_latency_1", "emg_latency_2",
        "emg_window_start", "emg_window_end",
        "emg_data_1", "emg_data_2",
    ],
    "Target Selection": [
        "row_type", "date", "time", "target_name",
        "coord_system", "loc_x", "loc_y", "loc_z",
        "m0n0", "m0n1", "m0n2",
        "m1n0", "m1n1", "m1n2",
        "m2n0", "m2n1", "m2n2",
    ],
    "Crosshairs Position": [
        "row_type", "date", "time", "crosshairs_driver",
        "coord_system", "loc_x", "loc_y", "loc_z",
        "m0n0", "m0n1", "m0n2",
        "m1n0", "m1n1", "m1n2",
        "m2n0", "m2n1", "m2n2",
    ],
}

# Columns that should be cast to float wherever they appear
_FLOAT_COLS = {
    "x", "y", "z",
    "loc_x", "loc_y", "loc_z",
    "m0n0", "m0n1", "m0n2",
    "m1n0", "m1n1", "m1n2",
    "m2n0", "m2n1", "m2n2",
    "emg_peak_to_peak_1", "emg_peak_to_peak_2",
    "emg_latency_1", "emg_latency_2",
    "emg_window_start", "emg_window_end",
}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def parse_brainsight(
    path: Union[str, Path],
    *,
    parse_datetime: bool = True,
    drop_null_rows: bool = False,
) -> dict[str, pd.DataFrame]:
    """Parse a Brainsight streamed-info text file.

    Parameters
    ----------
    path : str | Path
        Path to the .txt file exported by Brainsight.
    parse_datetime : bool
        If True (default), combine the 'date' and 'time' columns into a
        single 'datetime' column (pandas Timestamp, ms precision).
    drop_null_rows : bool
        If True, drop rows where all numeric/positional columns are NA
        (i.e. tracker frames where the tool was not visible).

    Returns
    -------
    dict[str, pd.DataFrame]
        One entry per row type.  Missing row types return an empty
        DataFrame with the correct columns.
    """
    path = Path(path)
    raw_lines = path.read_text(encoding="utf-8").splitlines()

    # Drop comment lines and blank lines
    data_lines = [l for l in raw_lines if l and not l.startswith("#")]

    # Parse metadata from header comments
    metadata = _parse_metadata(raw_lines)

    # Split each line once and bucket by row-type
    buckets: dict[str, list[list[str]]] = {rt: [] for rt in SCHEMAS}

    for line in data_lines:
        parts = line.split("\t")
        rt = parts[0]
        if rt in SCHEMAS:
            cols = SCHEMAS[rt]
            # Pad or trim to expected width
            parts_fixed = parts[:len(cols)]
            parts_fixed += [None] * (len(cols) - len(parts_fixed))
            buckets[rt].append(parts_fixed)

    # Build DataFrames
    result: dict[str, pd.DataFrame] = {}
    for rt, cols in SCHEMAS.items():
        rows = buckets[rt]
        if rows:
            df = pd.DataFrame(rows, columns=cols)
        else:
            df = pd.DataFrame(columns=cols)

        # Replace "(null)" and Python None with pd.NA
        df = df.replace({"(null)": pd.NA})
        df = df.apply(lambda col: col.map(lambda v: pd.NA if v is None else v))

        # Cast numeric columns
        for col in cols:
            if col in _FLOAT_COLS:
                df[col] = pd.to_numeric(df[col], errors="coerce")

        # Optionally combine date + time into a datetime column
        if parse_datetime and "date" in df.columns and "time" in df.columns:
            df.insert(
                3, "datetime",
                pd.to_datetime(
                    df["date"].astype(str) + " " + df["time"].astype(str),
                    format="%Y-%m-%d %H:%M:%S.%f",
                    errors="coerce",
                ),
            )

        if drop_null_rows:
            pos_cols = [c for c in ("x", "y", "z", "loc_x", "loc_y", "loc_z") if c in df.columns]
            if pos_cols:
                df = df.dropna(subset=pos_cols, how="all")

        result[rt] = df

    result["_metadata"] = metadata
    return result


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_metadata(lines: list[str]) -> dict:
    """Extract key-value pairs from the # comment header."""
    meta = {}
    for line in lines:
        if not line.startswith("#"):
            break
        m = re.match(r"#\s*([^:]+):\s*(.+)", line)
        if m:
            meta[m.group(1).strip()] = m.group(2).strip()
    return meta
