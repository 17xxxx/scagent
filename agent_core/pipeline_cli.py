#!/usr/bin/env python3
"""
pipeline_cli.py —— 确定性流水线命令行（无 LLM、无外网）
=========================================================
scAgent 的核心分析能力本来就不依赖大模型 —— 工具函数是确定的。
本入口把它暴露成命令行，于是：

  · 断网也能跑（除 R 容器外不需要任何外部服务）
  · 可脚本化、可进 CI、可被其它系统调用
  · LLM 只作为"自然语言前端"存在，挂了不影响分析

用法：
  python pipeline_cli.py status
  python pipeline_cli.py run --steps qc,pca,snn,anno
  python pipeline_cli.py viz --which dimplot,marker_viz
  python pipeline_cli.py run-viz                      # 跑全部可视化
  python pipeline_cli.py enrich --cell-groups "Monocytes,NK cells,T cells"
  python pipeline_cli.py markers --genes Cd3d,Cd79a,Lyz2
  python pipeline_cli.py tools
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, List

# 与 server.py / agent_main.py 共用同一批工具函数（零逻辑重复）
from tools import (
    check_pipeline_status,
    run_cell_ratio_viz,
    run_cell_type_annotation,
    run_dimplot,
    run_enrichment_analysis,
    run_heatmap,
    run_marker_visualization,
    run_pca_umap,
    run_qc_for_all_samples,
    run_snn_cluster,
)

PIPELINE = {
    "qc":   ("QC 质控",        run_qc_for_all_samples),
    "pca":  ("PCA/UMAP 降维",  run_pca_umap),
    "snn":  ("SNN 聚类",       run_snn_cluster),
    "anno": ("细胞注释",        run_cell_type_annotation),
}

VIZ = {
    "dimplot":    ("散点图",         run_dimplot),
    "marker_viz": ("标记基因可视化",  run_marker_visualization),
    "cell_ratio": ("细胞比例图",      run_cell_ratio_viz),
    "heatmap":    ("热图",           run_heatmap),
}


def _call(tool, params: Dict[str, Any]) -> Any:
    """调用 LangChain 工具（走 pydantic 校验）。"""
    return tool.invoke(params)


def _show(title: str, result: Any) -> bool:
    print(f"\n{'=' * 62}\n  {title}\n{'=' * 62}")
    if isinstance(result, dict):
        status = result.get("status")
        print(json.dumps(result, indent=2, ensure_ascii=False, default=str))
        return status in {"success", None}
    print(result)
    return True


def cmd_status(args) -> int:
    _show("流水线进度", _call(check_pipeline_status, {"project": args.project,
                                                   "data_dir": args.data_dir}))
    return 0


def cmd_tools(args) -> int:
    rows = list(PIPELINE.items()) + list(VIZ.items())
    print(f"{'key':<12}{'说明':<20}工具")
    print("-" * 62)
    for k, (desc, fn) in rows:
        print(f"{k:<12}{desc:<20}{fn.name}")
    print("-" * 62)
    print("其它: enrich（GO 富集）/ markers（标记基因可视化）/ status")
    return 0


def cmd_run(args) -> int:
    keys = [s.strip() for s in args.steps.split(",") if s.strip()]
    unknown = [k for k in keys if k not in PIPELINE]
    if unknown:
        print(f"❌ 未知步骤: {unknown}；可用: {list(PIPELINE)}", file=sys.stderr)
        return 2

    failed: List[str] = []
    for k in keys:                                   # 严格按用户给定顺序执行
        desc, tool = PIPELINE[k]
        ok = _show(f"[{k}] {desc}", _call(tool, {"project": args.project}))
        if not ok:
            failed.append(k)
            print(f"\n❌ [{k}] 失败，流水线中断（后续步骤依赖它）", file=sys.stderr)
            break                            # 流水线必须按顺序，失败即停
    if failed:
        return 1
    print(f"\n✅ 完成: {', '.join(keys)}")
    return 0


def cmd_viz(args) -> int:
    keys = [s.strip() for s in args.which.split(",") if s.strip()]
    unknown = [k for k in keys if k not in VIZ]
    if unknown:
        print(f"❌ 未知可视化: {unknown}；可用: {list(VIZ)}", file=sys.stderr)
        return 2

    # 标记基因可视化需要基因列表
    if "marker_viz" in keys and not args.genes:
        print("⚠️  marker_viz 需要 --genes（如 --genes Cd3d,Cd79a），已跳过该项")
        keys = [k for k in keys if k != "marker_viz"]

    failed = []
    for k in keys:
        desc, tool = VIZ[k]
        params: Dict[str, Any] = {"project": args.project}
        if k == "marker_viz":
            params["marker_genes"] = [g.strip() for g in args.genes.split(",") if g.strip()]
        if not _show(f"[{k}] {desc}", _call(tool, params)):
            failed.append(k)
    if failed:
        print(f"\n⚠️  以下可视化失败: {failed}", file=sys.stderr)
        return 1
    print(f"\n✅ 完成: {', '.join(keys)}")
    return 0


def cmd_markers(args) -> int:
    if not args.genes:
        print("❌ 需要 --genes，例如 --genes Cd3d,Cd79a,Lyz2", file=sys.stderr)
        return 2
    genes = [g.strip() for g in args.genes.split(",") if g.strip()]
    ok = _show("[marker_viz] 标记基因可视化",
               _call(run_marker_visualization,
                     {"project": args.project, "marker_genes": genes}))
    return 0 if ok else 1


def cmd_enrich(args) -> int:
    if not args.cell_groups:
        print("❌ 需要 --cell-groups，例如 --cell-groups \"Monocytes,NK cells\"",
              file=sys.stderr)
        return 2
    groups = [g.strip() for g in args.cell_groups.split(",") if g.strip()]
    ok = _show("[enrichment] GO 富集分析",
               _call(run_enrichment_analysis,
                     {"project": args.project, "cell_group_names": groups,
                      "species": args.species, "ont": args.ont}))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description="scAgent 确定性流水线（无 LLM、无外网）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("--project", default="scRNA_project", help="项目名（决定输出文件前缀）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("status", help="查看流水线进度")
    p.add_argument("--data-dir", default=None, help="数据根目录（默认取 SCAGENT_DATA_DIR）")
    p.set_defaults(func=cmd_status)

    sub.add_parser("tools", help="列出全部可用步骤").set_defaults(func=cmd_tools)

    p = sub.add_parser("run", help="执行流水线步骤（按给定顺序）")
    p.add_argument("--steps", default="qc,pca,snn,anno",
                   help="逗号分隔，可选: qc,pca,snn,anno")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("viz", help="执行可视化")
    p.add_argument("--which", default="dimplot,marker_viz,cell_ratio,heatmap",
                   help="逗号分隔，可选: dimplot,marker_viz,cell_ratio,heatmap")
    p.add_argument("--genes", default="", help="marker_viz 需要的基因列表")
    p.set_defaults(func=cmd_viz)

    p = sub.add_parser("markers", help="标记基因可视化（需 --genes）")
    p.add_argument("--genes", default="")
    p.set_defaults(func=cmd_markers)

    p = sub.add_parser("enrich", help="GO 功能富集（需 --cell-groups）")
    p.add_argument("--cell-groups", default="")
    p.add_argument("--species", default="mouse", choices=["mouse", "human"])
    p.add_argument("--ont", default="BP", choices=["BP", "CC", "MF", "ALL"])
    p.set_defaults(func=cmd_enrich)

    args = ap.parse_args()
    if getattr(args, "data_dir", None):
        import os
        os.environ["SCAGENT_DATA_DIR"] = args.data_dir
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
