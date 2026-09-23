import json

with open('handoffs/registry.json', 'r', encoding='utf-8') as f:
    data = json.load(f)

new_entry = {
    "run_id": "WF03-ISS0785-20260923",
    "requirement_id": None,
    "issue_id": "ISS-0785",
    "queue_task_id": 784,
    "github_issue_number": 1736,
    "status": "IN_PROGRESS",
    "owned_modules": [
        "lib/letflow/repository/attachments.ex",
        "lib/letflow/routers/instances.ex"
    ],
    "started_at": "2026-09-23T03:56:46Z",
    "lock_released_at": None,
    "released_lock": False,
    "last_known_step": "Step 00 dispatched to ELIXIR-DEV",
    "note": "WF-03 for ISS-0785: timing side-channel in Attachments.get_content/2 -- cross-instance-same-tenant denial costs 2 Repo round-trips (reads full blob) vs 1 for cross-tenant/never-issued. Fix: reorder lookup so instance_id check precedes artifact blob read. Queue task 784 (GH#1736)."
}
data['runs'].append(new_entry)

with open('handoffs/registry.json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')

print('Done. Total runs:', len(data['runs']))
