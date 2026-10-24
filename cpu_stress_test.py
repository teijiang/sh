#!/usr/bin/env python3
"""
CPU高负载测试脚本
用于测试在不同CPU负载等级下系统能运行多久
"""

import multiprocessing
import time
import sys
import signal
import datetime
import os

# 全局变量控制进程
running = True
processes = []

def cpu_intensive_task(intensity):
    """
    CPU密集型任务
    intensity: 负载强度 (0.0 到 1.0)
    """
    while running:
        # 执行计算密集型操作
        count = 0
        for _ in range(int(intensity * 1000000)):
            count += 1

        # 根据强度调整休眠时间
        if intensity < 1.0:
            time.sleep((1.0 - intensity) * 0.01)

def signal_handler(sig, frame):
    """处理Ctrl+C信号"""
    global running
    print("\n\n收到中断信号，正在停止所有进程...")
    running = False
    sys.exit(0)

def get_cpu_count():
    """获取CPU核心数"""
    return multiprocessing.cpu_count()

def start_stress_test(level):
    """
    启动压力测试
    level: 负载等级 (1-5)
    """
    global processes, running

    # 负载等级配置
    load_config = {
        1: {"name": "轻度负载 (20%)", "cores": 1, "intensity": 0.2},
        2: {"name": "中度负载 (40%)", "cores": 2, "intensity": 0.5},
        3: {"name": "重度负载 (60%)", "cores": max(2, get_cpu_count() // 2), "intensity": 0.7},
        4: {"name": "极重负载 (80%)", "cores": get_cpu_count(), "intensity": 0.8},
        5: {"name": "满负载 (100%)", "cores": get_cpu_count(), "intensity": 1.0}
    }

    if level not in load_config:
        print(f"错误: 无效的负载等级 {level}，请选择 1-5")
        return None

    config = load_config[level]
    cpu_count = get_cpu_count()

    print(f"\n{'='*60}")
    print(f"CPU压力测试")
    print(f"{'='*60}")
    print(f"系统CPU核心数: {cpu_count}")
    print(f"选择的负载等级: Level {level} - {config['name']}")
    print(f"使用CPU核心数: {config['cores']}")
    print(f"负载强度: {int(config['intensity'] * 100)}%")
    print(f"记录间隔: 10秒")
    print(f"开始时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*60}\n")

    # 创建日志文件
    log_filename = f"cpu_stress_log_level{level}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"

    with open(log_filename, 'w', encoding='utf-8') as f:
        f.write(f"CPU压力测试日志\n")
        f.write(f"{'='*60}\n")
        f.write(f"负载等级: Level {level} - {config['name']}\n")
        f.write(f"使用CPU核心数: {config['cores']}\n")
        f.write(f"负载强度: {int(config['intensity'] * 100)}%\n")
        f.write(f"开始时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"{'='*60}\n\n")

    print(f"日志文件: {log_filename}\n")

    # 启动工作进程
    running = True
    for i in range(config['cores']):
        p = multiprocessing.Process(target=cpu_intensive_task, args=(config['intensity'],))
        p.start()
        processes.append(p)
        print(f"启动工作进程 {i+1}/{config['cores']}")

    print(f"\n压力测试已启动! 按 Ctrl+C 停止测试\n")

    # 记录循环
    start_time = time.time()
    record_count = 0

    try:
        while running:
            time.sleep(10)  # 每10秒记录一次
            record_count += 1
            elapsed_time = time.time() - start_time
            current_time = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

            # 格式化运行时间
            hours = int(elapsed_time // 3600)
            minutes = int((elapsed_time % 3600) // 60)
            seconds = int(elapsed_time % 60)

            status_msg = f"[记录 #{record_count:04d}] 时间: {current_time} | 已运行: {hours:02d}:{minutes:02d}:{seconds:02d} | 状态: 运行中"

            # 输出到控制台
            print(status_msg)

            # 写入日志文件
            with open(log_filename, 'a', encoding='utf-8') as f:
                f.write(status_msg + '\n')

    except KeyboardInterrupt:
        print("\n\n测试被用户中断")
    finally:
        # 停止所有进程
        running = False
        print("\n正在停止所有工作进程...")
        for p in processes:
            p.terminate()
            p.join()

        # 记录结束信息
        end_time = time.time()
        total_time = end_time - start_time
        hours = int(total_time // 3600)
        minutes = int((total_time % 3600) // 60)
        seconds = int(total_time % 60)

        end_msg = f"\n{'='*60}\n"
        end_msg += f"测试结束时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
        end_msg += f"总运行时间: {hours:02d}:{minutes:02d}:{seconds:02d}\n"
        end_msg += f"总记录次数: {record_count}\n"
        end_msg += f"{'='*60}\n"

        print(end_msg)

        with open(log_filename, 'a', encoding='utf-8') as f:
            f.write(end_msg)

        print(f"\n日志已保存到: {log_filename}")

def main():
    """主函数"""
    # 设置信号处理
    signal.signal(signal.SIGINT, signal_handler)

    print("\n" + "="*60)
    print("CPU高负载压力测试工具")
    print("="*60)
    print("\n负载等级说明:")
    print("  1 - 轻度负载 (20%)   - 1核心，低强度")
    print("  2 - 中度负载 (40%)   - 2核心，中低强度")
    print("  3 - 重度负载 (60%)   - 多核心，中高强度")
    print("  4 - 极重负载 (80%)   - 全核心，高强度")
    print("  5 - 满负载 (100%)    - 全核心，最高强度")
    print("\n注意: 高负载可能导致系统响应缓慢或被强制关机")
    print("="*60 + "\n")

    # 获取用户输入
    if len(sys.argv) > 1:
        try:
            level = int(sys.argv[1])
        except ValueError:
            print("错误: 负载等级必须是1-5之间的数字")
            sys.exit(1)
    else:
        try:
            level = int(input("请选择负载等级 (1-5): "))
        except (ValueError, EOFError):
            print("\n使用默认等级: 3")
            level = 3

    if level < 1 or level > 5:
        print("错误: 负载等级必须在1-5之间")
        sys.exit(1)

    # 开始压力测试
    start_stress_test(level)

if __name__ == "__main__":
    main()
