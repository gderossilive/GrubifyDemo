import json, os

def read_json(path):
    if os.path.exists(path):
        with open(path) as f:
            try: return json.load(f)
            except: return None
    return None

def read_status(path):
    if os.path.exists(path):
        with open(path) as f: return f.read().strip()
    return "N/A"

# Files
status_files = read_status("/tmp/files_status.txt")
if status_files == "200":
    files_data = read_json("/tmp/files.json")
    if isinstance(files_data, list):
        indexed = sorted([f.get('fileName') if isinstance(f, dict) else f for f in files_data])
        with open("/tmp/expected_files.txt") as f:
            expected = [line.strip() for line in f if line.strip()]
        missing = [f for f in expected if f not in indexed]
        not_indexed = [f for f in indexed if f not in expected]
        print(f"Files: Indexed={len(indexed)}, Missing={len(missing)}, NotIndexedInSource={len(not_indexed)}")
    else: print(f"Files: Status 200 but unexpected format: {type(files_data)}")
else: print(f"Files: Status {status_files}")

# Connectors
status_conn = read_status("/tmp/connectors_status.txt")
if status_conn == "200":
    conn_data = read_json("/tmp/connectors.json")
    if isinstance(conn_data, list):
        names = [c.get('name') if isinstance(c, dict) else c for c in conn_data]
        teams = "Present" if any("Teams" in str(n) for n in names) else "Absent"
        print(f"Connectors: {', '.join(map(str, names))} (Teams: {teams})")
    else: print(f"Connectors: Status 200 but unexpected format")
else: print(f"Connectors: Status {status_conn}")

# Tools
status_tools = read_status("/tmp/tools_status.txt")
if status_tools == "200":
    tools_data = read_json("/tmp/tools.json")
    if isinstance(tools_data, list):
        tool_names = [t.get('name') if isinstance(t, dict) else t for t in tools_data]
        expected_tools = ["PostTeamsMessage", "GetTeamsMessages", "ReplyToTeamsMessage", "GetServiceNowIncident", "AcknowledgeServiceNowIncident", "PostServiceNowDiscussionEntry", "ResolveServiceNowIncident"]
        found = [t for t in expected_tools if t in tool_names]
        missing = [t for t in expected_tools if t not in tool_names]
        print(f"Tools: Found={len(found)}/{len(expected_tools)}, Missing={len(missing)}")
    else: print("Tools: Status 200 but unexpected format")
else: print(f"Tools: Status {status_tools}")

# Extended Agents
if os.path.exists("/tmp/ext_status.txt"):
    with open("/tmp/ext_status.txt") as f:
        ext_status_lines = f.readlines()
    parsed_ext = False
    for line in ext_status_lines:
        if ":" not in line: continue
        path, status = line.strip().split(": ")
        if status == "200":
            fname = "/tmp/ext_" + os.path.basename(path) + ".json"
            ext_data = read_json(fname)
            if ext_data:
                agents_list = ext_data if isinstance(ext_data, list) else ext_data.get('agents', [])
                if isinstance(agents_list, list):
                  agent_names = [a.get('name') if isinstance(a, dict) else a for a in agents_list]
                  expected = ["code-analyzer", "issue-triager", "incident-handler-core", "incident-handler-agt"]
                  found = [a for a in expected if a in agent_names]
                  print(f"Extended Agents: Found {', '.join(found)} in {path}")
                  parsed_ext = True
                  break
    if not parsed_ext: print(f"Extended Agents: Not found or status errors")

# Filter
status_filter = read_status("/tmp/filter_status.txt")
filter_obj = None
if status_filter == "200":
    filter_obj = read_json("/tmp/filter.json")
else:
    filters_all_data = read_json("/tmp/filters_all.json")
    if isinstance(filters_all_data, list):
        for f in filters_all_data:
            if isinstance(f, dict) and (f.get('id') == "grubify-http-errors" or f.get('name') == "grubify-http-errors"):
                filter_obj = f
                break
if isinstance(filter_obj, dict):
    print(f"Filter: ID={filter_obj.get('id')}, Agent={filter_obj.get('handlingAgent')}, Enabled={filter_obj.get('isEnabled')}, PrioritiesCount={len(filter_obj.get('priorities', []))}")
else:
    print(f"Filter: Not found (Status {status_filter})")

# ServiceNow Config
status_snow = read_status("/tmp/snow_status.txt")
if status_snow == "200":
    snow = read_json("/tmp/snow_config.json")
    if isinstance(snow, dict):
        ag = "Present" if snow.get('assignmentGroup') else "Blank"
        print(f"ServiceNow: Provider={snow.get('providerType')}, AssignmentGroup={ag}, LookbackDays={snow.get('lookbackDays')}")
    else: print("ServiceNow: Status 200 but unexpected format")
else: print(f"ServiceNow: Status {status_snow}")

# Triggers
status_trig = read_status("/tmp/triggers_status.txt")
if status_trig == "200":
    trig = read_json("/tmp/triggers.json")
    if isinstance(trig, list):
        names = [t.get('name') if isinstance(t, dict) else t for t in trig]
        print(f"Triggers: Count={len(trig)}, Names={', '.join(map(str, names))}")
    else: print("Triggers: Status 200 but unexpected format")
else: print(f"Triggers: Status {status_trig}")
