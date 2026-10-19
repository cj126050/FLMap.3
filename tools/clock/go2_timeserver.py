#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PC 侧授时服务（用户态，无需 root）

在 0.0.0.0:8000 提供 /time 接口，返回 PC 当前的 epoch（含纳秒小数）。
Go2 拓展坞上的 go2-clock 会定时拉取，用来纠正拓展坞的时钟。

用法:
    python3 go2_timeserver.py            # 前台运行，Ctrl-C 退出
    python3 go2_timeserver.py --port 8000
    python3 go2_timeserver.py --daemon   # 后台常驻（写日志到 /tmp/go2_timeserver.log）

自检:
    curl http://127.0.0.1:8000/time
"""

import argparse
import http.server
import os
import socket
import socketserver
import sys
import time


class TimeHandler(http.server.BaseHTTPRequestHandler):
    server_version = "Go2TimeServer/1.0"

    def do_GET(self):
        if self.path.split("?")[0] not in ("/", "/time", "/now"):
            self.send_error(404)
            return
        # 取时间戳尽量靠近写回包的时刻
        body = ("%.9f" % time.time()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # 只记录错误，避免每 30 秒刷一行
        pass


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--daemon", action="store_true")
    args = ap.parse_args()

    if args.daemon:
        if os.fork() > 0:
            sys.exit(0)
        os.setsid()
        if os.fork() > 0:
            sys.exit(0)
        log = open("/tmp/go2_timeserver.log", "ab", buffering=0)
        os.dup2(log.fileno(), 1)
        os.dup2(log.fileno(), 2)

    try:
        httpd = ReusableTCPServer((args.bind, args.port), TimeHandler)
    except OSError as e:
        print("[ERROR] 端口 %d 绑定失败: %s" % (args.port, e), file=sys.stderr)
        sys.exit(1)

    ip = "127.0.0.1"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.168.123.10", 1))
        ip = s.getsockname()[0]
        s.close()
    except OSError:
        pass

    print("[go2-timeserver] listening on %s:%d  (Go2 侧访问 http://%s:%d/time)"
          % (args.bind, args.port, ip, args.port))
    print("[go2-timeserver] now = %.9f" % time.time())
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[go2-timeserver] bye")


if __name__ == "__main__":
    main()
