# VectorLabel - Vectorworks ConnectCAD Circuit Export
# Exports selected ConnectCAD circuits to ~/Documents/VectorLabel/
# Each circuit produces two rows: one Source label, one Destination label.

import vs
import os
import csv
import time

EXPORT_FOLDER = os.path.expanduser('~/Documents/VectorLabel')
DIAGNOSTIC = False

# Internal field names confirmed from live diagnostic
# These are all the fields available on a ConnectCAD circuit object.
# The export produces two rows per circuit (Source + Destination),
# each with all fields available for use in label templates.
ALL_CIRCUIT_FIELDS = [
    'Number', 'Cable', 'Signal', 'Circuits',
    'CableLength', 'CableCalculatedLength', 'Number Display',
    'Cable Type', 'Cable Outside Diameter',
    # Source side
    'Src_Dev_Name', 'Src_Dev_Tag', 'Src_Skt_Name', 'Src_Skt_Tag',
    'Src_Signal', 'Src_Skt_Conn', 'Src_Skt_Circs',
    # Destination side
    'Dst_Dev_Name', 'Dst_Dev_Tag', 'Dst_Skt_Name', 'Dst_Skt_Tag',
    'Dst_Signal', 'Dst_Skt_Conn', 'Dst_Skt_Circs',
    'Dst_Room', 'Dst_Rack', 'Dst_RackU',
    # Circuit geometry/type
    'CircuitType',
]

# Fields that identify a circuit vs other EquipItem objects.
# A circuit has Src_Dev_Name or Dst_Dev_Name populated.
def is_circuit(fields):
    return bool(fields.get('Src_Dev_Name') or fields.get('Dst_Dev_Name')
                or fields.get('Signal') or fields.get('CircuitType'))


def get_fields(handle):
    """Read all fields from a ConnectCAD plugin object."""
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
    """Build one label row for the given side ('Source' or 'Destination')."""
    row = {'_Side': side}

    # Shared fields
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
        # For source label, other-end info
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
        # For destination label, other-end info
        row['Other_Device']   = fields.get('Src_Dev_Name', '')
        row['Other_Socket']   = fields.get('Src_Skt_Name', '')
        row['Other_Connector']= fields.get('Src_Skt_Conn', '')

    return row


def run_diagnostic(handle):
    fields = get_fields(handle)
    lines = ["=== RAW FIELDS ==="]
    for k, v in fields.items():
        if v and v not in ('False', '0', '0e00\'', '---', '0"'):
            lines.append("  {}: {}".format(k, v))
    diag_path = os.path.join(EXPORT_FOLDER, 'diagnostic.txt')
    os.makedirs(EXPORT_FOLDER, exist_ok=True)
    with open(diag_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    vs.AlrtDialog("Diagnostic written to:\n{}".format(diag_path))


def export_selected_circuits():
    selected_handles = []

    def collect(h):
        selected_handles.append(h)
        return True

    vs.ForEachObject(collect, "(SEL=TRUE)")

    if not selected_handles:
        vs.AlrtDialog("No objects selected. Select one or more ConnectCAD circuits.")
        return

    if DIAGNOSTIC:
        run_diagnostic(selected_handles[0])
        return

    rows = []
    skipped = 0

    for h in selected_handles:
        fields = get_fields(h)
        if not is_circuit(fields):
            skipped += 1
            continue
        rows.append(build_label_row(fields, 'Source'))
        rows.append(build_label_row(fields, 'Destination'))

    if not rows:
        vs.AlrtDialog("No ConnectCAD circuits found in selection.\n"
                      "({} non-circuit object(s) skipped)".format(skipped))
        return

    os.makedirs(EXPORT_FOLDER, exist_ok=True)

    # Build header from first row
    header = list(rows[0].keys())

    vw_file = os.path.splitext(os.path.basename(vs.GetFName()))[0]
    timestamp = time.strftime('%Y%m%d_%H%M%S')
    filename = '{}_export_{}.csv'.format(vw_file, timestamp)
    filepath = os.path.join(EXPORT_FOLDER, filename)

    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=header)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, '') for k in header})

    msg = "Exported {} label row(s) for {} circuit(s) to:\n{}".format(
        len(rows), len(rows) // 2, filepath)
    if skipped:
        msg += "\n({} non-circuit object(s) skipped)".format(skipped)
    vs.AlrtDialog(msg)


export_selected_circuits()
