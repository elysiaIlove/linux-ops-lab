#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Alertmanager webhook 接收端
监听 127.0.0.1:5001/webhook，接收告警推送并格式化写入日志

放置位置：~/ops-lab/scripts/alert_webhook.py
由 systemd 托管：/etc/systemd/system/alert-webhook.service

用法：
  前台运行（调试）： python3 alert_webhook.py
  后台服务：        由 systemd 托管

说明：
  选择 webhook 而非仅用邮件作为通知通道，原因：
    1. 无需凭据，链路完整且可在本地验证
    2. 真实 SRE 实践中 webhook 是主流（钉钉/企微/Slack）
    3. 邮件只是最后一个「投递通道」，其前的路由逻辑完全一致
"""
import json
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN_HOST = '127.0.0.1'
LISTEN_PORT = 5001
LOG_FILE = '/root/ops-lab/logs/alerts.log'
STATUS_MAP = {
    'firing':   '[FIRING]',
    'resolved': '[RESOLVED]',
}


def log(msg):
    """带时间戳追加写入日志，并同步打印到标准输出（便于 journalctl 查看）"""
    line = '[%s] %s' % (datetime.now().strftime('%Y-%m-%d %H:%M:%S'), msg)
    print(line, flush=True)
    with open(LOG_FILE, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


def format_alert(alert):
    """把单条告警格式化成多行文本"""
    name = alert.get('labels', {}).get('alertname', 'UnknownAlert')
    status = alert.get('status', 'unknown')
    tag = STATUS_MAP.get(status, '[%s]' % status.upper())
    lines = ['%s %s' % (tag, name)]

    # 关键标签（排除 alertname 和内部标签）
    skip = {'alertname'}
    labels = {k: v for k, v in alert.get('labels', {}).items()
              if k not in skip and not k.startswith('__')}
    if labels:
        lines.append('    标签: ' + ', '.join('%s=%s' % (k, v) for k, v in sorted(labels.items())))

    ann = alert.get('annotations', {})
    if ann.get('summary'):
        lines.append('    摘要: ' + ann['summary'])
    if ann.get('description'):
        lines.append('    详情: ' + ann['description'])

    if status == 'firing' and alert.get('startsAt'):
        lines.append('    开始: ' + alert['startsAt'])
    if status == 'resolved' and alert.get('endsAt'):
        lines.append('    恢复: ' + alert['endsAt'])
    return '\n'.join(lines)


class AlertHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        if self.path.rstrip('/') != '/webhook':
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length)

        try:
            payload = json.loads(raw.decode('utf-8'))
        except Exception as e:
            log('[ERROR] 解析告警 JSON 失败: %s' % e)
            self.send_response(400)
            self.end_headers()
            return

        status = payload.get('status', 'unknown')
        alerts = payload.get('alerts', [])
        log('========== 收到告警批次: %s，共 %d 条 ==========' % (status.upper(), len(alerts)))
        for a in alerts:
            for line in format_alert(a).split('\n'):
                log(line)

        # Alertmanager 需要收到 2xx 才认为通知成功，否则会重试
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def do_GET(self):
        """健康检查用"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.end_headers()
        self.wfile.write('alert webhook receiver is running\n'.encode('utf-8'))

    def log_message(self, fmt, *args):
        """屏蔽默认的访问日志，避免太吵"""
        pass


if __name__ == '__main__':
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), AlertHandler)
    print('alert webhook 监听 http://%s:%d/webhook' % (LISTEN_HOST, LISTEN_PORT), flush=True)
    server.serve_forever()
