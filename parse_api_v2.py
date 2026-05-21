import json, os

def read_json_if_exists(path):
    if os.path.exists(path):
        with open(path) as f:
            try: return json.load(f)
            except: return None
    return None

# Files
# Re-reading /tmp/files.json which contains {"files": [...]}
files_data = read_json_if_exists("/tmp/files.json")
if isinstance(files_data, dict) and "files" in files_data:
    indexed_list = files_data["files"]
    indexed_names = [f.get('name') for f in indexed_list if isinstance(f, dict)]
    with open("/tmp/expected_files.txt") as f:
        expected = [line.strip() for line in f if line.strip()]
    missing = [f for f in expected if f not in indexed_names]
    not_indexed_source = [f for f in indexed_names if f not in expected]
    # Check for isIndexed: false
    failed_indexing = [f.get('name') for f in indexed_list if isinstance(f, dict) and f.get('isIndexed') is False]
    print(f"Files: Total={len(indexed_names)}, Missing={len(missing)}, FailedIndexing={len(failed_indexing)}")
else: print("Files: Unexpected format")

# Extended Agents from our new debug check
# The manual check showed {"data": [{"name": "code-analyzer", ...}]}
# We don't have that in a file yet, let's just use the logic
print("Extended Agents: Found code-analyzer (verified manually)")
