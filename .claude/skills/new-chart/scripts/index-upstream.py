#!/usr/bin/env python3
"""Regenerate references/upstream-index.md from local clones of the two upstream chart repos.

    python3 .claude/skills/new-chart/scripts/index-upstream.py \
        [--bitnami ../../bitnami-charts] [--cloudpirates ../../cloud-pirates-helm-charts]

Defaults assume the layout ~/Desktop/repos/personal/{bitnami-charts,cloud-pirates-helm-charts,
knowledge/tiktuzki-gitops}. Stdlib only (no PyYAML): it reads a handful of well-known keys with
regexes, which is enough for these two repos' very regular Chart.yaml / values.yaml files.
"""
import argparse
import re
import subprocess
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
REPO = SKILL.parents[2]  # tiktuzki-gitops
OUT = SKILL / "references" / "upstream-index.md"

WORKLOADS = [("StatefulSet", "sts"), ("Deployment", "deploy"), ("DaemonSet", "ds"),
             ("CronJob", "cron")]
FEATURES = [("PodDisruptionBudget", "pdb"), ("NetworkPolicy", "netpol"),
            ("ServiceMonitor", "metrics"), ("HorizontalPodAutoscaler", "hpa"),
            ("Ingress", "ingress"), ("CustomResourceDefinition", "crds")]


def scalar(text, key):
  """Top-level scalar, including YAML folded continuation lines (Bitnami descriptions)."""
  m = re.search(rf"^{key}:[ \t]*(.*)\n((?:[ \t]+\S.*\n)*)", text, re.M)
  if not m:
    return ""
  val = " ".join([m.group(1)] + [l.strip() for l in m.group(2).splitlines()])
  return re.sub(r"\s+", " ", val.split(" #")[0]).strip().strip("'\"").lstrip(">|- ").strip()


def main_image(values):
  """registry/repository of the top-level `image:` block."""
  m = re.search(r"^image:\s*\n((?:[ \t]+.*\n|\s*\n)+)", values, re.M)
  if not m:
    return ""
  block = m.group(1)
  reg = re.search(r"^\s+registry:\s*['\"]?([^'\"\s#]*)", block, re.M)
  rep = re.search(r"^\s+repository:\s*['\"]?([^'\"\s#]+)", block, re.M)
  if not rep:
    return ""
  return f"{reg.group(1)}/{rep.group(1)}" if reg and reg.group(1) else rep.group(1)


def kinds(chart_dir):
  text = ""
  for f in (chart_dir / "templates").rglob("*"):
    if f.is_file():
      text += f.read_text(errors="ignore")
  found = lambda k: re.search(rf"kind:\s*{k}\b", text) is not None
  w = [s for k, s in WORKLOADS if found(k)]
  feats = [s for k, s in FEATURES if found(k)]
  if (chart_dir / "crds").is_dir():
    feats.append("crds") if "crds" not in feats else None
  if "existingSecret" in text:
    feats.append("existingSecret")
  return "/".join(w) or ("library" if not text else "—"), " ".join(feats)


def deps(chart_yaml):
  m = re.search(r"^dependencies:\s*\n((?:[ \t-].*\n)+)", chart_yaml, re.M)
  if not m:
    return ""
  names = re.findall(r"^\s*-?\s*name:\s*(\S+)", m.group(1), re.M)
  return ", ".join(n for n in names if n != "common")


def head(repo):
  try:
    return subprocess.check_output(["git", "-C", str(repo), "log", "-1", "--format=%h %cs"],
                                   text=True).strip()
  except Exception:
    return "unknown"


def scan(root):
  rows = []
  for cy in sorted(root.glob("*/Chart.yaml")):
    d = cy.parent
    c = cy.read_text(errors="ignore")
    v = (d / "values.yaml").read_text(errors="ignore") if (d / "values.yaml").exists() else ""
    w, feats = kinds(d)
    rows.append(dict(
      name=scalar(c, "name") or d.name, dir=d.name,
      version=scalar(c, "version"), app=scalar(c, "appVersion"),
      desc=scalar(c, "description").rstrip("."),
      category=CATEGORY_OF.get(d.name, "Library" if scalar(c, "type") == "library" else "Other"),
      image=main_image(v), workload=w, features=feats, deps=deps(c),
      type=scalar(c, "type") or "application"))
  return rows


# Bitnami Chart.yaml carries no category, so group by hand. Unlisted charts land in "Other" —
# add them here when a new one appears.
CATEGORY = {
  "Databases (SQL)": "postgresql postgresql-ha mysql mariadb mariadb-galera cloudnative-pg clickhouse clickhouse-operator",
  "Databases (NoSQL, search, graph)": "mongodb mongodb-sharded cassandra scylladb neo4j janusgraph kube-arangodb elasticsearch opensearch solr influxdb milvus",
  "Cache & key-value": "redis redis-cluster valkey valkey-cluster keydb memcached etcd consul zookeeper",
  "Messaging & streaming": "kafka rabbitmq rabbitmq-cluster-operator nats schema-registry flink spark",
  "Observability": "prometheus kube-prometheus thanos grafana grafana-alloy grafana-loki grafana-mimir grafana-operator grafana-tempo grafana-k6-operator jaeger zipkin fluentd fluent-bit logstash kibana node-exporter kube-state-metrics cadvisor metrics-server kubernetes-event-exporter victoriametrics",
  "Security & identity": "keycloak oauth2-proxy vault sealed-secrets cert-manager pinniped ejbca kiam",
  "Networking & ingress": "nginx nginx-ingress-controller haproxy contour envoy-gateway kong apisix external-dns metallb cilium multus-cni whereabouts",
  "Storage & object stores": "minio minio-operator seaweedfs",
  "CI/CD, GitOps & platform": "argo-cd argo-workflows flux jenkins gitlab-runner gitea harbor concourse chainloop sonarqube",
  "Data, ML & analytics": "airflow superset dremio nessie mlflow jupyterhub kuberay deepspeed pytorch tensorflow-resnet matomo",
  "Web apps & CMS": "wordpress drupal ghost moodle mastodon discourse odoo redmine appsmith parse phpmyadmin",
  "Runtimes & app servers": "apache tomcat wildfly aspnet-core",
}
CATEGORY_OF = {c: cat for cat, names in CATEGORY.items() for c in names.split()}


def provenance(chart_yaml):
  low = chart_yaml.lower()
  if "cloudpirates" in low:
    return "cp"
  if "bitnami" in low and "bitnamicharts" not in low:
    return "bn"
  return "own"


def esc(s, cap=140):
  """First sentence only, capped — the table is for scanning, the chart README for detail."""
  s = re.split(r"(?<=[a-z0-9)])\. ", s, maxsplit=1)[0]
  if len(s) > cap:
    s = s[:cap].rsplit(" ", 1)[0] + "…"
  return s.replace("|", "\\|")


def main():
  ap = argparse.ArgumentParser()
  base = REPO.parents[1]
  ap.add_argument("--bitnami", type=Path, default=base / "bitnami-charts")
  ap.add_argument("--cloudpirates", type=Path, default=base / "cloud-pirates-helm-charts")
  a = ap.parse_args()

  bn = scan(a.bitnami / "bitnami")
  cp = scan(a.cloudpirates / "charts")
  # name → "cp" | "bn" | "own": a same-named chart we wrote ourselves is NOT the upstream one
  ours = {p.parent.name: provenance(p.read_text(errors="ignore"))
          for p in (REPO / "charts").glob("*/Chart.yaml")}
  secure_only = sorted(d.name for d in (a.bitnami / "bitnami").iterdir()
                       if d.is_dir() and not (d / "Chart.yaml").exists())

  def here(name, src):
    p = ours.get(name)
    return "" if p is None else ("vendored" if p == src else f"own `{name}`")

  cp_names = {r["dir"] for r in cp}
  # same software under a different chart name
  alias = {"postgres": "postgresql"}
  cp_cover = {alias.get(n, n) for n in cp_names} - {"common"}  # the two libraries differ

  L = []
  L.append("# Upstream Chart Index\n")
  L.append("**Generated — do not edit by hand.** Rebuild with "
           "`python3 .claude/skills/new-chart/scripts/index-upstream.py`.\n")
  L.append(f"- Bitnami: `bitnami-charts/bitnami/` @ {head(a.bitnami)} — {len(bn)} charts")
  L.append(f"- CloudPirates: `cloud-pirates-helm-charts/charts/` @ {head(a.cloudpirates)} — "
           f"{len(cp)} charts\n")
  L.append("Columns: **workload** = controllers the chart renders (sts/deploy/ds/cron). "
           "**features** = optional resources it can render (pdb, netpol, metrics = "
           "ServiceMonitor, hpa, ingress, crds) and `existingSecret` = accepts a pre-made Secret "
           "(needed for SealedSecrets). **here** = `vendored` (this upstream chart is copied into `charts/`) or "
           "`own x` (we wrote our own chart of that name — read it first). "
           "**CP** = CloudPirates also packages it (prefer that one — see SKILL.md).\n")

  L.append("## CloudPirates\n")
  L.append("Official upstream images, non-root by default, `values.schema.json` in every chart. "
           "Library: `cloudpirates/common`.\n")
  L.append("| chart | ver | app | image | workload | features | deps | here | description |")
  L.append("|---|---|---|---|---|---|---|---|---|")
  for r in cp:
    L.append(f"| `{r['dir']}` | {r['version']} | {r['app']} | `{r['image']}` | {r['workload']} "
             f"| {r['features']} | {r['deps']} | {here(r['dir'], 'cp')} "
             f"| {esc(r['desc'])} |")

  L.append("\n## Bitnami\n")
  L.append("⚠️ Since 2025-08-28 `docker.io/bitnami/*` only publishes hardened `latest` tags; "
           "versioned tags moved to `docker.io/bitnamilegacy/*` and get **no updates**. "
           "Treat these charts as a **template library**, not something to deploy with "
           "default images. Library: `bitnami/common`.\n")
  cats = {}
  for r in bn:
    cats.setdefault(r["category"] or ("Library" if r["type"] == "library" else "Other"),
                    []).append(r)
  order = list(CATEGORY) + ["Other", "Library"]

  def slug(t):
    return re.sub(r"[^a-z0-9 -]", "", t.lower()).replace(" ", "-")

  L.append("Categories: " + " · ".join(f"[{c}](#{slug(c)})" for c in order if c in cats) + "\n")
  for c in [c for c in order if c in cats]:
    L.append(f"### {c}\n")
    L.append("| chart | ver | app | workload | features | deps | here | CP | description |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for r in cats[c]:
      L.append(f"| `{r['dir']}` | {r['version']} | {r['app']} | {r['workload']} "
               f"| {r['features']} | {r['deps']} | {here(r['dir'], 'bn')} "
               f"| {'✓' if r['dir'] in cp_cover else ''} | {esc(r['desc'])} |")
    L.append("")

  if secure_only:
    L.append("### Secure Images only (no chart source here)\n")
    L.append("README-only directories — these charts ship only through the paid Bitnami Secure "
             "Images programme: " + ", ".join(f"`{n}`" for n in secure_only) + ".\n")

  OUT.parent.mkdir(parents=True, exist_ok=True)
  OUT.write_text("\n".join(L).rstrip() + "\n")
  print(f"wrote {OUT.relative_to(REPO)}: {len(cp)} cloudpirates + {len(bn)} bitnami charts")


if __name__ == "__main__":
  main()
