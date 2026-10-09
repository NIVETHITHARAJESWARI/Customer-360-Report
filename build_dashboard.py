"""Inject dashboard_data.json into dashboard_template.html -> customer360_dashboard.html, then open it."""
import json, webbrowser
from pathlib import Path

HERE = Path(__file__).parent


def build(open_browser=True):
    raw = json.loads((HERE / "dashboard_data.json").read_text())
    data = {k: raw[k] for k in ("cust", "monthly_cut", "category_cut")}
    html = (HERE / "dashboard_template.html").read_text(encoding="utf-8")
    out = HERE / "customer360_dashboard.html"
    out.write_text(html.replace("__DATA__", json.dumps(data, separators=(",", ":"))), encoding="utf-8")
    print(f"Dashboard written: {out}")
    if open_browser:
        webbrowser.open(out.as_uri())


if __name__ == "__main__":
    build()
