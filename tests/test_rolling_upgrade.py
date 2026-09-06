def test_rolling_triggers_sorted():
    workers = {
        "talos-worker-03": {"ip": "192.0.2.13"},
        "talos-worker-01": {"ip": "192.0.2.11"},
        "talos-worker-02": {"ip": "192.0.2.12"},
    }
    sorted_ips = ",".join(sorted([v["ip"] for v in workers.values()]))
    assert sorted_ips == "192.0.2.11,192.0.2.12,192.0.2.13"
