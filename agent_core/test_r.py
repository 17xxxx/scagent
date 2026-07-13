"""
test_r.py —— 从主容器调用 R 后端 run_test 自检
用法: python agent_core/test_r.py
"""
import requests

SEURAT_URL = "http://seurat:9000"


def _unwrap(value):
    """plumber 将 R 字符向量序列化为 JSON 数组，此函数提取标量"""
    if isinstance(value, list) and len(value) > 0:
        return value[0]
    return value


def call_run_test():
    print("=== 触发 R 容器 run_test 自检 ===")
    try:
        res = requests.get(f"{SEURAT_URL}/api/run_test")
        print("  状态码:", res.status_code)
        data = res.json()
        print("  回应:", data)

        status = _unwrap(data.get("status"))
        message = _unwrap(data.get("message"))

        if status == "success":
            print("\n  run_test 全部通过")
        else:
            print("\n  run_test 失败:", message)
    except requests.ConnectionError:
        print("  ✗ 无法连接 R 容器 (seurat:9000)，请确认容器已启动")
    except Exception as e:
        print("  ✗ 调用失败:", e)


if __name__ == "__main__":
    call_run_test()
