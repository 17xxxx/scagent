import requests


def test_infrastructure():
    print("=== 开始测试 DevContainer 架构连通性 ===")

    # 测试网络通信 (由于在同一个 compose 网络，直接用服务名 seurat)
    try:
        print("\n1. 正在 Ping R 容器...")
        res = requests.get("http://seurat:9000/ping")
        print("   R 容器回应:", res.json())
    except Exception as e:
        print("   网络通信失败:", e)

    # 测试文件共享
    try:
        print("\n2. 正在让 R 容器读取共享数据...")
        res = requests.get("http://seurat:9000/read_test")
        print("   R 容器读取到的内容:", res.json())
    except Exception as e:
        print("   文件读取失败:", e)


if __name__ == "__main__":
    test_infrastructure()
