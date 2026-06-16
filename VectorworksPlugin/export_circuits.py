# VectorLabel - Vectorworks ConnectCAD Circuit Export
# Exports selected ConnectCAD circuits to:
#   ~/Documents/VectorLabel/Exports/<VectorworksFileName>/
# Each project folder keeps a maximum of MAX_EXPORTS_PER_PROJECT files.
# Pruning is based on the datecode embedded in the filename, not file system
# metadata, so it works correctly across copies, cloud sync, etc.

import vs
import os
import csv
import re
import time

# ── Configuration ─────────────────────────────────────────────────────────────

BASE_FOLDER         = os.path.expanduser('~/Documents/VectorLabel')
EXPORTS_FOLDER      = os.path.join(BASE_FOLDER, 'Exports')
MAX_EXPORTS_PER_PROJECT = 15   # keep 15 most recent per project folder
DIAGNOSTIC          = False

# Regex that matches the datecode in our export filenames.
# Example: ESM_Kodak_Hall_Master_export_20260614_172508.csv
# Matches the _export_YYYYMMDD_HHMMSS portion and captures the datecode.
EXPORT_DATECODE_RE = re.compile(r'_export_(\d{8}_\d{6})\.csv$', re.IGNORECASE)


# ── Helpers ───────────────────────────────────────────────────────────────────

def is_circuit(fields):
    """Identify a ConnectCAD circuit vs other EquipItem objects."""
    return bool(fields.get('Src_Dev_Name') or fields.get('Dst_Dev_Name')
                or fields.get('Signal') or fields.get('CircuitType'))


def get_fields(handle):
    """Read all parametric fields from a ConnectCAD plugin object."""
    param_record = vs.GetParametricRecord(handle)
    if not param_record:
        return {}
    pio_name = vs.GetName(param_record)
    num_fields = vs.NumFields(param_record)
    fields = {}
    for i in range(1, num_fields + 1):
        fname = vs.GetFldName(param_record, i)
        if fname:
            fields[fname] = vs.GetRField(handle, pio_name, fname) or ''
    return fields


def build_label_row(fields, side):
    """Build one label CSV row for Source or Destination side."""
    row = {'_Side': side}

    for f in ['Number', 'Cable', 'Signal', 'Circuits', 'CableLength',
              'CableCalculatedLength', 'Number Display', 'Cable Type',
              'Cable Outside Diameter', 'CircuitType']:
        row[f] = fields.get(f, '')

    if side == 'Source':
        row['Device_Name']    = fields.get('Src_Dev_Name', '')
        row['Device_Tag']     = fields.get('Src_Dev_Tag', '')
        row['Socket_Name']    = fields.get('Src_Skt_Name', '')
        row['Socket_Tag']     = fields.get('Src_Skt_Tag', '')
        row['Socket_Signal']  = fields.get('Src_Signal', '')
        row['Connector']      = fields.get('Src_Skt_Conn', '')
        row['Socket_Circs']   = fields.get('Src_Skt_Circs', '')
        row['Room']           = ''
        row['Rack']           = ''
        row['RackU']          = ''
        row['Other_Device']   = fields.get('Dst_Dev_Name', '')
        row['Other_Socket']   = fields.get('Dst_Skt_Name', '')
        row['Other_Connector']= fields.get('Dst_Skt_Conn', '')
    else:
        row['Device_Name']    = fields.get('Dst_Dev_Name', '')
        row['Device_Tag']     = fields.get('Dst_Dev_Tag', '')
        row['Socket_Name']    = fields.get('Dst_Skt_Name', '')
        row['Socket_Tag']     = fields.get('Dst_Skt_Tag', '')
        row['Socket_Signal']  = fields.get('Dst_Signal', '')
        row['Connector']      = fields.get('Dst_Skt_Conn', '')
        row['Socket_Circs']   = fields.get('Dst_Skt_Circs', '')
        row['Room']           = fields.get('Dst_Room', '')
        row['Rack']           = fields.get('Dst_Rack', '')
        row['RackU']          = fields.get('Dst_RackU', '')
        row['Other_Device']   = fields.get('Src_Dev_Name', '')
        row['Other_Socket']   = fields.get('Src_Skt_Name', '')
        row['Other_Connector']= fields.get('Src_Skt_Conn', '')

    return row


def prune_project_folder(folder_path, keep=MAX_EXPORTS_PER_PROJECT):
    """
    Delete oldest exports beyond `keep` limit, using the datecode in the
    filename (_export_YYYYMMDD_HHMMSS.csv) — NOT file system metadata.

    Files that do not match the expected naming pattern are left untouched.
    """
    try:
        all_files = [
            f for f in os.listdir(folder_path)
            if f.lower().endswith('.csv')
        ]
    except OSError:
        return

    # Only consider files whose names contain a valid datecode
    dated_files = []
    for fname in all_files:
        match = EXPORT_DATECODE_RE.search(fname)
        if match:
            datecode = match.group(1)   # e.g. "20260614_172508"
            dated_files.append((datecode, fname))

    # Sort by datecode string — lexicographic order = chronological order
    # because format is YYYYMMDD_HHMMSS (zero-padded, fixed width)
    dated_files.sort(key=lambda x: x[0])

    # Delete all but the `keep` most recent
    to_delete = dated_files[:-keep] if len(dated_files) > keep else []
    deleted = []
    for datecode, fname in to_delete:
        try:
            os.remove(os.path.join(folder_path, fname))
            deleted.append(fname)
        except OSError:
            pass   # skip files we can't delete (permissions, etc.)

    return deleted


def run_diagnostic(handle):
    """Write raw field values to diagnostic.txt for debugging."""
    fields = get_fields(handle)
    lines = ["=== RAW FIELDS ==="]
    for k, v in fields.items():
        if v and v not in ('False', '0', "0e00'", '---', '0"'):
            lines.append("  {}: {}".format(k, v))
    diag_path = os.path.join(BASE_FOLDER, 'diagnostic.txt')
    os.makedirs(BASE_FOLDER, exist_ok=True)
    with open(diag_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    vs.AlrtDialog("Diagnostic written to:\n{}".format(diag_path))


# ── Export core ───────────────────────────────────────────────────────────────

def collect_handles(criteria):
    """Collect every object handle matching a Vectorworks criteria string."""
    handles = []

    def collect(h):
        handles.append(h)
        return True

    vs.ForEachObject(collect, criteria)
    return handles


def write_export(handles, empty_msg):
    """Turn circuit handles into a CSV export. Silent on success; alerts only
    when there's nothing to export. `empty_msg` accepts a {skipped} placeholder."""
    rows = []
    skipped = 0

    for h in handles:
        fields = get_fields(h)
        if not is_circuit(fields):
            skipped += 1
            continue
        rows.append(build_label_row(fields, 'Source'))
        rows.append(build_label_row(fields, 'Destination'))

    if not rows:
        vs.AlrtDialog(empty_msg.format(skipped=skipped))
        return

    # Derive project folder name from the Vectorworks filename (no extension)
    vw_file = os.path.splitext(os.path.basename(vs.GetFName()))[0]

    # Build path: ~/Documents/VectorLabel/Exports/<VWFileName>/
    project_folder = os.path.join(EXPORTS_FOLDER, vw_file)
    os.makedirs(project_folder, exist_ok=True)

    # Build filename with embedded datecode for reliable pruning
    timestamp = time.strftime('%Y%m%d_%H%M%S')
    filename  = '{}_export_{}.csv'.format(vw_file, timestamp)
    filepath  = os.path.join(project_folder, filename)

    # Write CSV
    header = list(rows[0].keys())
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=header)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, '') for k in header})

    # Prune old exports for this project (datecode-based, not mtime-based)
    prune_project_folder(project_folder, keep=MAX_EXPORTS_PER_PROJECT)

    # No success dialog — the export completes silently and VectorLabel picks up
    # the new CSV automatically. (Error conditions above still alert the user.)


# ── Menu commands ─────────────────────────────────────────────────────────────

def export_selected_circuits():
    """'Export Selected Circuits to VectorLabel' — only the current selection."""
    handles = collect_handles("(SEL=TRUE)")
    if not handles:
        vs.AlrtDialog("No objects selected. Select one or more ConnectCAD circuits.")
        return
    if DIAGNOSTIC:
        run_diagnostic(handles[0])
        return
    write_export(handles,
                 "No ConnectCAD circuits found in selection.\n"
                 "({skipped} non-circuit object(s) skipped)")


def export_all_circuits():
    """'Export All Circuits to VectorLabel' — every circuit on the active layer."""
    layer_name = vs.GetLName(vs.ActLayer())
    handles = collect_handles("(L='{}')".format(layer_name))
    write_export(handles,
                 "No ConnectCAD circuits found on the active layer ('{}').\n"
                 "({{skipped}} non-circuit object(s) skipped)".format(layer_name))


# ── Entry point ───────────────────────────────────────────────────────────────
# This one file backs TWO Vectorworks menu commands. When pasting it into the
# Plug-in Manager, leave exactly ONE of the calls below active per command:
#
#   Command "Export Selected Circuits to VectorLabel"  →  export_selected_circuits()
#   Command "Export All Circuits to VectorLabel"        →  export_all_circuits()

export_selected_circuits()
# export_all_circuits()
