#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pcat-net-led.py — photonicat 板载网络状态灯控制工具

通过 pcat-manager 的 Unix socket（/tmp/pcat-manager.sock）下发灯状态，并从本地
状态文件读取最近一次成功下发的设置。仅使用标准库（socket/json/argparse/os/sys/
time/tempfile），无第三方依赖。

协议要点（板上实测验证）：
  * 传输：Unix SOCK_STREAM；消息以字节 0x00 (NUL) 结尾作为定界；
  * JSON 键名必须精确为 "command"（不是 "cmd"）；
  * 请求示例：{"command":"net-status-led-set","on_time":100,"down_time":0,"repeat":0}
  * 服务端异步写出响应：sendall 后需 sleep 约 0.5s 再 recv，再循环 recv 直到收到
    以 \\x00 结尾的完整响应或超时；
  * 响应为 json-c 序列化（键间带空格）并带 \\x00 结尾，如
    { "command": "net-status-led-set", "code": 0, "result": true }
  * MCU/驱动没有查询接口：get 读取的是本地状态文件，不能反映 MCU 实时灯态或被
    外部（如非 distro 模式下 mwan）改动的状态。
"""

import argparse
import json
import os
import socket
import sys
import tempfile
import time

# ---------------- 常量区 ----------------

DEFAULT_SOCKET = "/tmp/pcat-manager.sock"
DEFAULT_STATE_FILE = "/var/lib/pcat-net-led-state.json"

# LED 语义档位 → (on_time, down_time, repeat)，与 pcat-manager main.c 一致
LED_PRESETS = {
    "on": (100, 0, 0),       # 常亮
    "off": (0, 100, 0),      # 熄灭
    "wired": (50, 50, 0),    # 快闪
    "mobile": (20, 380, 0),  # 慢闪
    "unknown": (100, 0, 0),  # 同 on，常亮
}

TIME_VALUE_MIN = 0
TIME_VALUE_MAX = 65535

RESPONSE_DELAY = 0.5   # 服务端异步写出，发送后需等待其 flush 再 recv
RECV_TIMEOUT = 2.0     # recv 超时（秒）
RECV_CHUNK = 4096      # 单次 recv 缓冲大小

MSG_NO_RESPONSE = "未收到响应，请确认 pcat-manager 服务运行且 --socket 路径正确"

GET_DESCRIPTION = (
    "读取最近一次成功下发的灯设置并输出。注意：MCU/驱动没有查询接口，本命令返回的"
    "是本地状态文件记录的最后一次成功下发内容，无法反映 MCU 实时灯态，也无法反映"
    "被外部（如非 distro 模式下 mwan）改动的状态。"
)


# ---------------- 子函数 ----------------

def build_payload_set(on_time, down_time, repeat):
    """构造 set 命令请求字节串：紧凑 JSON + b'\\x00' 定界（键名必须为 "command"）。"""
    payload = {
        "command": "net-status-led-set",
        "on_time": on_time,
        "down_time": down_time,
        "repeat": repeat,
    }
    return json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\x00"


def send_recv_json(socket_path, request_bytes):
    """向 pcat-manager socket 发送请求并接收响应。

    返回 (raw, err)：
      * raw 为收到的全部原始字节（含 \\x00）、err 为 None：收到数据；
      * raw 为 b""、err 为 None：未收到响应（超时或对端关闭且无数据）；
      * raw 为 None、err 为中文说明：连接/收发过程异常。
    """
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(RECV_TIMEOUT)
    try:
        try:
            sock.connect(socket_path)
        except OSError as exc:
            return None, "连接 socket 失败: %s" % exc
        try:
            sock.sendall(request_bytes)
            # 服务端异步写出响应，需等待其 flush 后再 recv，避免连接关闭导致丢包
            time.sleep(RESPONSE_DELAY)
            buf = b""
            while True:
                try:
                    chunk = sock.recv(RECV_CHUNK)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
                if b"\x00" in buf:
                    break
            return buf, None
        except OSError as exc:
            return None, "收发响应失败: %s" % exc
    finally:
        sock.close()


def load_state(path):
    """读取状态文件；不存在、解析失败或内容非 JSON 对象时返回 None。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def save_state(path, state):
    """原子写入状态文件：写临时文件后 os.replace，父目录缺失时自动创建。

    成功返回 None，失败返回中文错误说明。
    """
    parent = os.path.dirname(path) or "."
    try:
        os.makedirs(parent, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=parent, prefix=".pcat-net-led-", suffix=".tmp")
    except OSError as exc:
        return "状态目录创建失败: %s" % exc
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False)
        os.replace(tmp_path, path)
        return None
    except Exception as exc:
        return "写入状态文件失败: %s" % exc
    finally:
        try:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError:
            pass


def _timestamp_now():
    """当前时间，ISO 8601 格式并含时区偏移（如 2026-08-22T14:31:56+0800）。"""
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def _validate_timing(on_time, down_time, repeat):
    """校验三个时序数值均在 [0, 65535]；越界返回 (参数名, 值)，合法返回 None。"""
    for name, value in (("on_time", on_time), ("down_time", down_time), ("repeat", repeat)):
        if not TIME_VALUE_MIN <= value <= TIME_VALUE_MAX:
            return name, value
    return None


def _extract_response_segment(raw):
    """提取原始响应中第一个非空分段（跳过首段空字节串）；找不到返回 None。"""
    for segment in raw.split(b"\x00"):
        if segment:
            return segment
    return None


def cmd_get(args):
    """get 子命令：读取状态文件并输出最近一次成功下发的灯设置。"""
    state = load_state(args.state_file)
    if state is None:
        print("no record: 尚未设置过灯状态", file=sys.stderr)
        return 1
    if args.json:
        # 原样输出状态文件 JSON（保留文件原始内容）
        try:
            with open(args.state_file, "r", encoding="utf-8") as f:
                sys.stdout.write(f.read())
        except OSError as exc:
            print("读取状态文件失败: %s" % exc, file=sys.stderr)
            return 1
        return 0
    led = state.get("led")
    if led is not None:
        print("led: %s" % led)
    for key in ("on_time", "down_time", "repeat"):
        print("%s: %s" % (key, state.get(key, 0)))
    if "updated" in state:
        print("updated: %s" % state["updated"])
    return 0


def cmd_set(args):
    """set 子命令：下发灯状态到 pcat-manager 并保存状态文件。"""
    if args.led is not None:
        on_time, down_time, repeat = LED_PRESETS[args.led]
        led_name = args.led
    else:
        on_time = args.on_time
        down_time = args.down_time if args.down_time is not None else 0
        repeat = args.repeat if args.repeat is not None else 0
        led_name = None

    bad = _validate_timing(on_time, down_time, repeat)
    if bad is not None:
        name, value = bad
        print("%s 越界: %d（允许范围 %d–%d，未发送）"
              % (name, value, TIME_VALUE_MIN, TIME_VALUE_MAX), file=sys.stderr)
        return 1

    payload = build_payload_set(on_time, down_time, repeat)
    raw, err = send_recv_json(args.socket, payload)
    if err is not None:
        print(err, file=sys.stderr)
        return 1
    if not raw:
        print(MSG_NO_RESPONSE, file=sys.stderr)
        return 1

    segment = _extract_response_segment(raw)
    if segment is None:
        print(MSG_NO_RESPONSE, file=sys.stderr)
        return 1
    try:
        resp = json.loads(segment.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        print("响应解析失败，原始字节:", repr(segment), file=sys.stderr)
        return 1

    if resp.get("code") == 0 and resp.get("result") is True:
        state = {
            "on_time": on_time,
            "down_time": down_time,
            "repeat": repeat,
            "updated": _timestamp_now(),
        }
        if led_name is not None:
            state["led"] = led_name
        save_err = save_state(args.state_file, state)
        print("灯状态设置成功")
        print("response:", json.dumps(resp, ensure_ascii=False))
        if save_err is not None:
            print("命令已下发成功，但状态文件保存失败: %s" % save_err, file=sys.stderr)
            return 1
        return 0

    print("灯状态设置失败（code=%r）" % resp.get("code", "?"), file=sys.stderr)
    if resp.get("error") is not None:
        print("error:", resp["error"], file=sys.stderr)
    else:
        print("response:", json.dumps(resp, ensure_ascii=False), file=sys.stderr)
    return 1


def build_parser():
    """构造 argparse 解析器（get/set 双子命令，帮助均为中文）。"""
    parser = argparse.ArgumentParser(
        prog="pcat-net-led.py",
        description="photonicat 板载网络状态灯控制工具：通过 pcat-manager 的 Unix "
                    "socket（/tmp/pcat-manager.sock，JSON+NUL 定界协议）下发灯状态，"
                    "并从本地状态文件读取最近一次成功下发的设置。",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True, metavar="子命令")

    p_get = sub.add_parser("get", help="读取最近一次成功下发的灯设置",
                           description=GET_DESCRIPTION)
    p_get.add_argument("--state-file", default=DEFAULT_STATE_FILE,
                       help="状态文件路径（默认 %(default)s）")
    p_get.add_argument("--json", action="store_true",
                       help="原样输出状态文件 JSON")
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set", help="下发灯状态到 pcat-manager")
    mode = p_set.add_mutually_exclusive_group()
    mode.add_argument("--led", choices=sorted(LED_PRESETS),
                      help="LED 语义档位: %(choices)s（on/unknown 常亮、off 熄灭、"
                           "wired 快闪、mobile 慢闪）")
    mode.add_argument("--on-time", type=int, metavar="MS",
                      help="自定义时序: 亮时长(ms)（%d–%d），提供后 --down-time/"
                           "--repeat 缺省为 0" % (TIME_VALUE_MIN, TIME_VALUE_MAX))
    # --down-time/--repeat 为自定义时序的补充参数（与 --on-time 组合使用）；它们与
    # --led 的互斥关系在 main 中人工校验（argparse 互斥组无法表达"可与 --on-time
    # 组合但不可与 --led 组合"的部分互斥）。
    p_set.add_argument("--down-time", type=int, metavar="MS",
                       help="自定义时序: 灭时长(ms)（%d–%d），与 --on-time 配合使用（默认 0）"
                            % (TIME_VALUE_MIN, TIME_VALUE_MAX))
    p_set.add_argument("--repeat", type=int, metavar="N",
                       help="自定义时序: 重复次数（%d–%d），与 --on-time 配合使用（默认 0）"
                            % (TIME_VALUE_MIN, TIME_VALUE_MAX))
    p_set.add_argument("--socket", default=DEFAULT_SOCKET,
                       help="pcat-manager Unix socket 路径（默认 %(default)s）")
    p_set.add_argument("--state-file", default=DEFAULT_STATE_FILE,
                       help="状态文件路径（默认 %(default)s）")
    p_set.set_defaults(func=cmd_set)

    return parser


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
        if args.subcommand == "set":
            if args.led is None and args.on_time is None:
                parser.error("--led 或 --on-time 至少提供一个")
            if args.led is not None and (args.down_time is not None or args.repeat is not None):
                parser.error("--led 与 --down-time/--repeat 不能同时使用")
    except SystemExit as exc:
        # 统一退出码：--help 正常退出(0)保持不变，其余参数错误一律 exit 1
        code = exc.code or 0
        raise SystemExit(0 if code == 0 else 1)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
