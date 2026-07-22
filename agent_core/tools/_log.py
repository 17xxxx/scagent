"""工具调用日志 —— 发送到 R 容器前统一打印参数名和参数值。"""


def log_api_call(tool_name: str, r_params: dict) -> None:
    """在向 R 容器发送 POST 请求前，打印 tool_name 及所有参数键值对。

    Args:
        tool_name: 工具名称标识（如 "qc", "pca", "heatmap" 等）
        r_params: 发送给 R 后端的参数字典
    """
    print(f"\n{'=' * 50}")
    print(f"[{tool_name}] 发送到 R 容器:")
    print(f"  tool_name : {tool_name}")
    print("  params:")
    for k, v in r_params.items():
        if k == "samples" and isinstance(v, dict):
            print(f"    {k} : {list(v.keys()) if v else {}}")
        else:
            print(f"    {k} : {v}")
    print(f"{'=' * 50}\n")
