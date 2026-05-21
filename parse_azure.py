import json, os

def read_json(path):
    if os.path.exists(path):
        with open(path) as f:
            try: return json.load(f)
            except: return None
    return None

# Roles
roles = read_json("/tmp/roles.json")
if roles:
    monitoring_reader_app = any(r['role'] == 'Monitoring Reader' and 'rg-grubify-app-agt01' in r['scope'] for r in roles)
    monitoring_contrib_app = any(r['role'] == 'Monitoring Contributor' and 'rg-grubify-app-agt01' in r['scope'] for r in roles)
    monitoring_reader_sre = any(r['role'] == 'Monitoring Reader' and 'rg-grubify-sre-agt01' in r['scope'] for r in roles)
    print(f"Roles: Monitoring Reader (App): {monitoring_reader_app}, Monitoring Contributor (App): {monitoring_contrib_app}, Monitoring Reader (SRE): {monitoring_reader_sre}")
else: print("Roles: No role assignments found")

# User Roles
user_roles = read_json("/tmp/user_roles.json")
if user_roles:
    admin = any('SRE Agent Administrator' in r['role'] for r in user_roles)
    print(f"User Admin: {admin}")
else: print("User Admin: Not found")

# Logic App
la = read_json("/tmp/logic_app.json")
if la:
    print(f"Logic App: State={la.get('state')}, Provisioning={la.get('provisioningState')}")
else: print("Logic App: Not found")

runs = read_json("/tmp/la_runs.json")
if runs:
    statuses = [r.get('status') for r in runs]
    print(f"Logic App Runs: {', '.join(statuses)}")
else: print("Logic App Runs: None found")
