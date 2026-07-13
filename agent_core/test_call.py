import requests

SEURAT_URL = "http://seurat:9000"


def test_qc_tool():
    """测试 QC 工具调用"""
    print("\n1. 测试 QC 工具 (run_quality_control)...")
    payload = {
        "tool_name": "qc",
        "params": {
            "data_path": "/workspace/data/raw_data/KM0/",
            "min_cells": 3,
            "min_features": 200
        }
    }
    try:
        res = requests.post(f"{SEURAT_URL}/api/execute_task", json=payload)
        print("   状态码:", res.status_code)
        print("   回应:", res.json())
    except Exception as e:
        print("   QC 调用失败:", e)


def test_unknown_tool():
    """测试未知工具的错误处理"""
    print("\n2. 测试未知工具 (预期返回错误)...")
    payload = {
        "tool_name": "nonexistent_tool",
        "params": {}
    }
    try:
        res = requests.post(f"{SEURAT_URL}/api/execute_task", json=payload)
        print("   状态码:", res.status_code)
        print("   回应:", res.json())
    except Exception as e:
        print("   未知工具调用失败:", e)


def test_infrastructure():
    print("=== 开始测试 DevContainer 架构连通性 ===")

    test_qc_tool()
    test_unknown_tool()

    print("\n=== 测试完成 ===")


if __name__ == "__main__":
    test_infrastructure()
