#!/usr/bin/env python3
# ============================================================
# TimeMachine Backup - API Server
# ============================================================
# Production-grade HTTP API server replacing the bash+socat
# implementation. Uses Python's ThreadingHTTPServer for proper
# concurrent request handling (1000+ simultaneous users).
#
# All state files, config, and log formats are identical to the
# bash implementation — this is a drop-in replacement.
#
# Usage:
#   tm-api-server.py [--bind ADDR] [--port PORT] [--project-root DIR]
# ============================================================

import os
import sys
import json
import glob
import time
import signal
import subprocess
import threading
import re
import mimetypes
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import unquote, urlparse, parse_qs
from datetime import datetime, timedelta
from pathlib import Path


# ============================================================
# CONFIGURATION
# ============================================================

def load_env(env_file):
    """Load .env file into a dict (does NOT modify os.environ)."""
    env = {}
    if not os.path.isfile(env_file):
        return env
    with open(env_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            key, _, val = line.partition('=')
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            env[key] = val
    return env


def get_config(project_root):
    """Load configuration from .env with defaults."""
    env_file = os.path.join(project_root, '.env')
    env = load_env(env_file)

    home_dir = env.get('TM_HOME', '/home/timemachine')
    return {
        'project_root': project_root,
        'backup_root': env.get('TM_BACKUP_ROOT', os.path.join(project_root, 'backups')),
        'home_dir': home_dir,
        'log_dir': env.get('TM_LOG_DIR', os.path.join(home_dir, 'logs')),
        'state_dir': env.get('TM_STATE_DIR', os.path.join(home_dir, 'state')),
        'run_dir': env.get('TM_RUN_DIR', '/var/run/timemachine'),
        'ssh_key': env.get('TM_SSH_KEY', os.path.expanduser('~/.ssh/id_ed25519')),
        'schedule_hour': env.get('TM_SCHEDULE_HOUR', '11'),
        'schedule_minute': env.get('TM_SCHEDULE_MINUTE', '0'),
        'retention_days': env.get('TM_RETENTION_DAYS', '7'),
        'parallel_jobs': env.get('TM_PARALLEL_JOBS', '5'),
        'alert_enabled': env.get('TM_ALERT_ENABLED', 'false'),
        'alert_email': env.get('TM_ALERT_EMAIL', ''),
        'notify_backup_ok': env.get('TM_NOTIFY_BACKUP_OK', 'true'),
        'notify_backup_fail': env.get('TM_NOTIFY_BACKUP_FAIL', 'true'),
        'notify_restore_ok': env.get('TM_NOTIFY_RESTORE_OK', 'true'),
        'notify_restore_fail': env.get('TM_NOTIFY_RESTORE_FAIL', 'true'),
        'alert_email_backup_ok': env.get('TM_ALERT_EMAIL_BACKUP_OK', ''),
        'alert_email_backup_fail': env.get('TM_ALERT_EMAIL_BACKUP_FAIL', ''),
        'alert_email_restore_ok': env.get('TM_ALERT_EMAIL_RESTORE_OK', ''),
        'alert_email_restore_fail': env.get('TM_ALERT_EMAIL_RESTORE_FAIL', ''),
        'env_file': env_file,
        '_raw': env,
    }


# Global config — reloaded on signal
CONFIG = {}
CONFIG_LOCK = threading.Lock()
SERVICE_START_TIME = int(time.time())
SCRIPT_DIR = ''


def reload_config():
    global CONFIG
    with CONFIG_LOCK:
        CONFIG = get_config(CONFIG['project_root'])


def env_val(key, default=''):
    """Read a config value (from .env or defaults)."""
    with CONFIG_LOCK:
        # Map key to config dict key
        key_map = {
            'TM_SCHEDULE_HOUR': 'schedule_hour',
            'TM_SCHEDULE_MINUTE': 'schedule_minute',
            'TM_RETENTION_DAYS': 'retention_days',
            'TM_PARALLEL_JOBS': 'parallel_jobs',
            'TM_ALERT_ENABLED': 'alert_enabled',
            'TM_ALERT_EMAIL': 'alert_email',
            'TM_NOTIFY_BACKUP_OK': 'notify_backup_ok',
            'TM_NOTIFY_BACKUP_FAIL': 'notify_backup_fail',
            'TM_NOTIFY_RESTORE_OK': 'notify_restore_ok',
            'TM_NOTIFY_RESTORE_FAIL': 'notify_restore_fail',
            'TM_ALERT_EMAIL_BACKUP_OK': 'alert_email_backup_ok',
            'TM_ALERT_EMAIL_BACKUP_FAIL': 'alert_email_backup_fail',
            'TM_ALERT_EMAIL_RESTORE_OK': 'alert_email_restore_ok',
            'TM_ALERT_EMAIL_RESTORE_FAIL': 'alert_email_restore_fail',
        }
        mapped = key_map.get(key)
        if mapped:
            return CONFIG.get(mapped, default)
        # Also check raw env
        return CONFIG.get('_raw', {}).get(key, default)


def env_set(key, val):
    """Update or append a key=value in .env file."""
    env_file = CONFIG.get('env_file', '')
    if not env_file:
        return
    lines = []
    found = False
    if os.path.isfile(env_file):
        with open(env_file, 'r') as f:
            lines = f.readlines()
    new_lines = []
    for line in lines:
        if line.strip().startswith(key + '='):
            new_lines.append(f'{key}={val}\n')
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f'{key}={val}\n')
    with open(env_file, 'w') as f:
        f.writelines(new_lines)


# ============================================================
# HELPERS
# ============================================================

def state_dir():
    return CONFIG.get('state_dir', os.path.join(CONFIG.get('home_dir', '/home/timemachine'), 'state'))


def log_dir():
    return CONFIG.get('log_dir', '/var/log/timemachine')


def backup_root():
    return CONFIG.get('backup_root', '')


def project_root():
    return CONFIG.get('project_root', '')


def get_hostname():
    import socket
    return socket.gethostname()


def get_version():
    vf = os.path.join(project_root(), 'VERSION')
    try:
        return open(vf).read().strip()
    except Exception:
        return 'unknown'


def parse_json_body(body_bytes):
    try:
        return json.loads(body_bytes.decode('utf-8', errors='replace'))
    except Exception:
        return {}


def is_process_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def get_processes_json():
    """Read all proc-*.state files and return list of process dicts."""
    sd = state_dir()
    procs = []
    for sf in sorted(glob.glob(os.path.join(sd, 'proc-*.state')), reverse=True):
        try:
            content = open(sf).read().strip()
            parts = content.split('|')
            if len(parts) < 6:
                continue
            pid, hostname, mode, started, status, logfile = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
            # Check if running process is still alive (skip PID 0 placeholder)
            if status == 'running' and pid != '0' and not is_process_alive(pid):
                status = 'completed'
                # 1. Check exit code file (most reliable)
                exit_file = os.path.join(sd, f'exit-{hostname}.code')
                if os.path.isfile(exit_file):
                    try:
                        ec = open(exit_file).read().strip()
                        if ec and ec != '0':
                            status = 'failed'
                    except Exception:
                        pass
                # 2. Scan entire log for [ERROR] markers
                if status != 'failed' and logfile and os.path.isfile(logfile):
                    try:
                        log_content = open(logfile).read()
                        if re.search(r'\[ERROR\s*\]', log_content):
                            status = 'failed'
                    except Exception:
                        pass
                content_new = content.replace('|running|', f'|{status}|')
                with open(sf, 'w') as f:
                    f.write(content_new)
            procs.append({
                'pid': int(pid) if pid.isdigit() else 0,
                'hostname': hostname,
                'mode': mode,
                'started': started,
                'status': status,
                'logfile': os.path.basename(logfile) if logfile else '',
            })
        except Exception:
            continue
    # Sort: running first, then by started time descending
    procs.sort(key=lambda p: (0 if p['status'] == 'running' else 1, p.get('started', '')), reverse=False)
    # For non-running, reverse the started sort (newest first)
    running = [p for p in procs if p['status'] == 'running']
    finished = [p for p in procs if p['status'] != 'running']
    finished.sort(key=lambda p: p.get('started', ''), reverse=True)
    return running + finished


def parse_priority(line):
    m = re.search(r'--priority\s+(\d+)', line)
    return int(m.group(1)) if m else 10


def parse_db_interval(line):
    m = re.search(r'--db-interval\s+(\d+)h?', line)
    return int(m.group(1)) if m else 0


def parse_backup_interval(line):
    m = re.search(r'--backup-interval\s+(\d+)h?', line)
    return int(m.group(1)) if m else 0


def _parse_server_line(line):
    """Parse a servers.conf line into a server dict."""
    parts = line.split(None, 1)
    hostname = parts[0]
    opts = parts[1] if len(parts) > 1 else ''
    prio = parse_priority(line)
    db_int = parse_db_interval(line)
    bk_int = parse_backup_interval(line)
    files_only = '--files-only' in opts
    db_only = '--db-only' in opts
    no_rotate = '--no-rotate' in opts
    notify = ''
    nm = re.search(r'--notify\s+(\S+)', opts)
    if nm:
        notify = nm.group(1)
    return {
        'hostname': hostname,
        'options': opts,
        'priority': prio,
        'db_interval': db_int,
        'backup_interval': bk_int,
        'files_only': files_only,
        'db_only': db_only,
        'no_rotate': no_rotate,
        'notify_email': notify,
    }


def read_servers_conf():
    conf = os.path.join(project_root(), 'config', 'servers.conf')
    servers = []
    if not os.path.isfile(conf):
        return servers
    with open(conf) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            servers.append(_parse_server_line(line))
    return servers


def read_archived_conf():
    """Read archived servers from config/archived.conf."""
    conf = os.path.join(project_root(), 'config', 'archived.conf')
    servers = []
    if not os.path.isfile(conf):
        return servers
    with open(conf) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            srv = _parse_server_line(line)
            # Add snapshot info from backup_root
            snap_dir = os.path.join(backup_root(), srv['hostname'])
            snaps = []
            legacy_snaps = []
            if os.path.isdir(snap_dir):
                snaps = sorted([d for d in os.listdir(snap_dir)
                               if os.path.isdir(os.path.join(snap_dir, d))
                               and re.match(r'\d{4}-\d{2}-\d{2}', d)], reverse=True)
                legacy_snaps = sorted([d for d in os.listdir(snap_dir)
                                      if os.path.isdir(os.path.join(snap_dir, d))
                                      and re.match(r'daily\.\d{4}-\d{2}-\d{2}$', d)], reverse=True)
            total_size = '--'
            try:
                result = subprocess.run(['du', '-sh', snap_dir], capture_output=True, text=True, timeout=30)
                if result.returncode == 0:
                    total_size = result.stdout.split()[0]
            except Exception:
                pass
            # Count unique dates (YYYY-MM-DD) across current and legacy formats
            all_dates = set(s[:10] for s in snaps)
            all_dates.update(s[6:] for s in legacy_snaps)  # strip "daily." prefix
            srv['snapshots'] = len(all_dates)
            all_snaps = snaps + legacy_snaps
            srv['last_backup'] = sorted(all_snaps, reverse=True)[0] if all_snaps else '--'
            srv['total_size'] = total_size
            servers.append(srv)
    return servers


def archive_server(hostname):
    """Move a server from servers.conf to archived.conf. Returns the config line."""
    conf = os.path.join(project_root(), 'config', 'servers.conf')
    archived = os.path.join(project_root(), 'config', 'archived.conf')
    if not os.path.isfile(conf):
        return None
    lines = open(conf).readlines()
    new_lines = []
    archived_line = None
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#') and stripped.split()[0] == hostname:
            archived_line = stripped
        else:
            new_lines.append(line)
    if not archived_line:
        return None
    with open(conf, 'w') as f:
        f.writelines(new_lines)
    # Append to archived.conf
    with open(archived, 'a') as f:
        f.write(archived_line + '\n')
    return archived_line


def unarchive_server(hostname):
    """Move a server from archived.conf back to servers.conf."""
    conf = os.path.join(project_root(), 'config', 'servers.conf')
    archived = os.path.join(project_root(), 'config', 'archived.conf')
    if not os.path.isfile(archived):
        return None
    lines = open(archived).readlines()
    new_lines = []
    restored_line = None
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#') and stripped.split()[0] == hostname:
            restored_line = stripped
        else:
            new_lines.append(line)
    if not restored_line:
        return None
    with open(archived, 'w') as f:
        f.writelines(new_lines)
    # Append to servers.conf
    with open(conf, 'a') as f:
        f.write(restored_line + '\n')
    return restored_line


def delete_server_data_bg(hostname):
    """Delete all backup data for a server in the background. Returns immediately."""
    snap_dir = os.path.join(backup_root(), hostname)
    sd = state_dir()
    state_file = os.path.join(sd, f'delete-{hostname}.state')
    if not os.path.isdir(snap_dir):
        return
    # Write state file
    with open(state_file, 'w') as f:
        f.write(f'running|{hostname}|{int(time.time())}')
    def _do_delete():
        try:
            # Use sudo rm -rf because backup dirs may be owned by root
            # (rsync preserves ownership from remote servers)
            result = subprocess.run(
                ['sudo', 'rm', '-rf', snap_dir],
                capture_output=True, text=True, timeout=3600)
            if result.returncode == 0 or not os.path.exists(snap_dir):
                with open(state_file, 'w') as f:
                    f.write(f'completed|{hostname}|{int(time.time())}')
            else:
                err = result.stderr.strip() or 'rm failed'
                with open(state_file, 'w') as f:
                    f.write(f'failed|{hostname}|{int(time.time())}|{err}')
        except Exception as e:
            with open(state_file, 'w') as f:
                f.write(f'failed|{hostname}|{int(time.time())}|{str(e)}')
    t = threading.Thread(target=_do_delete, daemon=True)
    t.start()


def get_delete_tasks():
    """Get all background deletion tasks."""
    sd = state_dir()
    tasks = []
    for sf in glob.glob(os.path.join(sd, 'delete-*.state')):
        try:
            content = open(sf).read().strip()
            parts = content.split('|')
            tasks.append({
                'hostname': parts[1] if len(parts) > 1 else '?',
                'status': parts[0],
                'started': int(parts[2]) if len(parts) > 2 else 0,
                'error': parts[3] if len(parts) > 3 else '',
            })
        except Exception:
            continue
    return tasks


def tail_file(filepath, lines=500):
    """Read last N lines of a file."""
    try:
        with open(filepath, 'rb') as f:
            # Seek to end
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return ''
            # Read last chunk
            chunk_size = min(size, lines * 200)
            f.seek(max(0, size - chunk_size))
            data = f.read().decode('utf-8', errors='replace')
            result_lines = data.splitlines()[-lines:]
            return '\n'.join(result_lines)
    except Exception:
        return ''


def du_sh(path):
    """Get human-readable size of a path."""
    try:
        result = subprocess.run(['du', '-sh', path], capture_output=True, text=True, timeout=30)
        return result.stdout.split('\t')[0].strip() if result.returncode == 0 else '--'
    except Exception:
        return '--'


# ============================================================
# THREADED HTTP SERVER
# ============================================================

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle requests in separate threads for concurrency."""
    daemon_threads = True
    allow_reuse_address = True
    # Increase request queue size for high concurrency
    request_queue_size = 128

    def handle_error(self, request, client_address):
        """Suppress BrokenPipeError and ConnectionResetError from crashing threads."""
        exc_type = sys.exc_info()[0]
        if exc_type in (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            return  # Client disconnected — harmless, don't log
        super().handle_error(request, client_address)


class APIHandler(BaseHTTPRequestHandler):
    """HTTP request handler for all API and static file routes."""

    # Suppress default logging to stderr
    def log_message(self, format, *args):
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text, content_type='text/plain', status=200):
        body = text.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, filepath, content_type=None):
        if not os.path.isfile(filepath):
            self._send_json({'error': 'Not found'}, 404)
            return
        if content_type is None:
            content_type, _ = mimetypes.guess_type(filepath)
            content_type = content_type or 'application/octet-stream'
        try:
            with open(filepath, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(data)
        except Exception:
            self._send_json({'error': 'Failed to read file'}, 500)

    def _send_download(self, filepath, filename, content_type):
        try:
            with open(filepath, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
            self.send_header('Content-Length', len(data))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(data)
        except Exception:
            self._send_json({'error': 'Failed to send file'}, 500)

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 0:
            return self.rfile.read(length)
        return b''

    # ----------------------------------------------------------
    # ROUTING
    # ----------------------------------------------------------

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        try:
            self._route_get()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _route_get(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)

        # --- API routes ---
        if path == '/api/status':
            self._api_status()
        elif path == '/api/processes':
            self._api_processes()
        elif path.startswith('/api/db-versions/'):
            self._api_db_versions(path[len('/api/db-versions/'):])
        elif path.startswith('/api/snapshots/'):
            self._api_snapshots(path[len('/api/snapshots/'):])
        elif path.startswith('/api/browse/'):
            self._api_browse(path[len('/api/browse/'):])
        elif path.startswith('/api/download/'):
            self._api_download(path[len('/api/download/'):], query)
        elif path == '/api/restores':
            self._api_restores_list()
        elif path.startswith('/api/restore-log/'):
            self._api_restore_log(path[len('/api/restore-log/'):])
        elif path == '/api/servers':
            self._api_servers_list()
        elif path == '/api/settings':
            self._api_settings_get()
        elif path == '/api/ssh-key':
            self._api_ssh_key()
        elif path == '/api/ssh-key/raw':
            self._api_ssh_key_raw()
        elif path.startswith('/api/rsync-log/'):
            self._api_rsync_log(path[len('/api/rsync-log/'):])
        elif path.startswith('/api/logs/'):
            self._api_logs(path[len('/api/logs/'):])
        elif path == '/api/system':
            self._api_system()
        elif path == '/api/failures':
            self._api_failures()
        elif path == '/api/history':
            self._api_history()
        elif path == '/api/disk':
            self._api_disk()
        elif path == '/api/archived':
            self._api_archived_list()
        elif path == '/api/excludes':
            self._api_excludes_get()
        elif path.startswith('/api/excludes/'):
            self._api_excludes_get(path[len('/api/excludes/'):])
        # --- Static files ---
        elif path in ('/', '/index.html'):
            self._send_file(os.path.join(project_root(), 'web', 'index.html'), 'text/html')
        elif path == '/style.css':
            self._send_file(os.path.join(project_root(), 'web', 'style.css'), 'text/css')
        elif path == '/app.js':
            self._send_file(os.path.join(project_root(), 'web', 'app.js'), 'application/javascript')
        elif path == '/502.html':
            self._send_file(os.path.join(project_root(), 'web', '502.html'), 'text/html')
        elif path == '/favicon.ico':
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            # Try serving from web/ directory
            web_path = os.path.join(project_root(), 'web', path.lstrip('/'))
            if os.path.isfile(web_path):
                self._send_file(web_path)
            else:
                self._send_json({'error': f'Not found: {path}'}, 404)

    def do_POST(self):
        try:
            self._route_post()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _route_post(self):
        path = unquote(urlparse(self.path).path)
        body = self._read_body()

        if path == '/api/backup-all':
            self._api_backup_all()
        elif path.startswith('/api/backup/'):
            self._api_backup_start(path[len('/api/backup/'):], body)
        elif path.startswith('/api/restore/'):
            self._api_restore_start(path[len('/api/restore/'):], body)
        elif path == '/api/servers':
            self._api_servers_add(body)
        elif path.startswith('/api/archived/') and path.endswith('/unarchive'):
            hostname = path[len('/api/archived/'):-len('/unarchive')]
            self._api_archived_unarchive(hostname)
        elif path == '/api/test-email':
            self._api_test_email(body)
        else:
            self._send_json({'error': f'Not found: POST {path}'}, 404)

    def do_PUT(self):
        try:
            self._route_put()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _route_put(self):
        path = unquote(urlparse(self.path).path)
        body = self._read_body()

        if path == '/api/settings':
            self._api_settings_put(body)
        elif path == '/api/excludes':
            self._api_excludes_put(body)
        elif path.startswith('/api/excludes/'):
            self._api_excludes_put(body, path[len('/api/excludes/'):])
        elif path.startswith('/api/servers/'):
            self._api_servers_update(path[len('/api/servers/'):], body)
        else:
            self._send_json({'error': f'Not found: PUT {path}'}, 404)

    def do_DELETE(self):
        try:
            self._route_delete()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _route_delete(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)

        if path == '/api/failures':
            self._api_failures_clear()
        elif path.startswith('/api/failures/'):
            self._api_failure_dismiss(path[len('/api/failures/'):])
        elif path == '/api/processes':
            self._api_processes_clear()
        elif path.startswith('/api/processes/'):
            self._api_process_delete(path[len('/api/processes/'):])
        elif path == '/api/restores':
            self._api_restores_clear()
        elif path.startswith('/api/restore/'):
            self._api_restore_delete(path[len('/api/restore/'):])
        elif path.startswith('/api/backup/'):
            self._api_backup_kill(path[len('/api/backup/'):])
        elif path.startswith('/api/servers/'):
            action = query.get('action', [''])[0]
            hostname = path[len('/api/servers/'):]
            if action == 'archive':
                self._api_servers_archive(hostname)
            elif action == 'delete':
                self._api_servers_full_delete(hostname)
            else:
                self._api_servers_archive(hostname)
        elif path.startswith('/api/archived/'):
            self._api_archived_delete(path[len('/api/archived/'):])
        else:
            self._send_json({'error': f'Not found: DELETE {path}'}, 404)

    # ----------------------------------------------------------
    # API IMPLEMENTATIONS
    # ----------------------------------------------------------

    def _api_status(self):
        procs = get_processes_json()
        uptime_secs = int(time.time()) - SERVICE_START_TIME
        # Check if any backups ran today (look for today's log files)
        today = datetime.now().strftime('%Y-%m-%d')
        ld = log_dir()
        today_logs = glob.glob(os.path.join(ld, f'backup-*-{today}_*.log'))
        has_running = any(p['status'] == 'running' for p in procs)
        self._send_json({
            'status': 'running',
            'uptime': uptime_secs,
            'hostname': get_hostname(),
            'version': get_version(),
            'processes': procs,
            'backups_today': len(today_logs) > 0 or has_running,
        })

    def _api_processes(self):
        self._send_json(get_processes_json())

    def _api_processes_clear(self):
        """Delete all finished (completed/failed) process state files."""
        sd = state_dir()
        cleared = 0
        for sf in glob.glob(os.path.join(sd, 'proc-*.state')):
            try:
                content = open(sf).read().strip()
                parts = content.split('|')
                if len(parts) >= 5 and parts[4] in ('completed', 'failed'):
                    os.remove(sf)
                    # Also remove exit code file
                    hostname = parts[1]
                    exit_file = os.path.join(sd, f'exit-{hostname}.code')
                    if os.path.isfile(exit_file):
                        os.remove(exit_file)
                    cleared += 1
            except Exception:
                continue
        self._send_json({'cleared': cleared})

    def _api_failures_clear(self):
        """Dismiss all failures by deleting log files that contain errors."""
        ld = log_dir()
        removed = 0
        logs = sorted(glob.glob(os.path.join(ld, 'backup-*.log')),
                       key=os.path.getmtime, reverse=True)[:50]
        for logfile in logs:
            try:
                log_tail = tail_file(logfile, 50)
                if re.search(r'\[ERROR\]|FAIL|fatal|Permission denied|cannot create', log_tail, re.IGNORECASE):
                    os.remove(logfile)
                    removed += 1
            except Exception:
                continue
        self._send_json({'dismissed': removed})

    def _api_failure_dismiss(self, hostname):
        """Dismiss failures for a specific hostname by deleting its error log files."""
        ld = log_dir()
        removed = 0
        for logfile in glob.glob(os.path.join(ld, f'backup-{hostname}-*.log')):
            try:
                log_tail = tail_file(logfile, 50)
                if re.search(r'\[ERROR\]|FAIL|fatal|Permission denied|cannot create', log_tail, re.IGNORECASE):
                    os.remove(logfile)
                    removed += 1
            except Exception:
                continue
        # Also remove exit code file so server list status resets
        exit_file = os.path.join(state_dir(), f'exit-{hostname}.code')
        if os.path.isfile(exit_file):
            os.remove(exit_file)
        self._send_json({'dismissed': removed})

    def _api_process_delete(self, hostname):
        """Delete finished (completed/failed) process state files for a specific host."""
        sd = state_dir()
        cleared = 0
        for sf in glob.glob(os.path.join(sd, f'proc-{hostname}*.state')):
            try:
                content = open(sf).read().strip()
                parts = content.split('|')
                if len(parts) >= 5 and parts[4] in ('completed', 'failed'):
                    os.remove(sf)
                    cleared += 1
            except Exception:
                continue
        # Also remove exit code file
        exit_file = os.path.join(sd, f'exit-{hostname}.code')
        if os.path.isfile(exit_file):
            os.remove(exit_file)
        if cleared > 0:
            self._send_json({'cleared': cleared})
        else:
            self._send_json({'error': 'No finished process found for ' + hostname}, 404)

    def _api_snapshots(self, hostname):
        snap_dir = os.path.join(backup_root(), hostname)
        snaps = []
        # Cutoff: 3 months ago
        cutoff = (datetime.now() - timedelta(days=90)).strftime('%Y-%m-%d')
        if os.path.isdir(snap_dir):
            for entry in sorted(os.listdir(snap_dir)):
                full = os.path.join(snap_dir, entry)
                if not os.path.isdir(full):
                    continue
                # Match current (YYYY-MM-DD, YYYY-MM-DD_HHMMSS) and legacy (daily.YYYY-MM-DD)
                date_str = None
                if re.match(r'^\d{4}-\d{2}-\d{2}(_\d{6})?$', entry):
                    date_str = entry[:10]
                elif re.match(r'^daily\.\d{4}-\d{2}-\d{2}$', entry):
                    date_str = entry[6:]  # strip "daily." prefix
                else:
                    continue
                if date_str < cutoff:
                    continue
                sz = du_sh(full)
                has_files = os.path.isdir(os.path.join(full, 'files'))
                has_db = False
                db_versions = 0
                sql_dir = os.path.join(full, 'sql')
                if os.path.isdir(sql_dir):
                    db_files = [f for f in os.listdir(sql_dir) if os.path.isfile(os.path.join(sql_dir, f))]
                    has_db = len(db_files) > 0
                    if has_db:
                        db_versions = 1
                    # Count timestamped subdirs (HHMMSS) as additional versions
                    db_versions += len([d for d in os.listdir(sql_dir)
                                        if os.path.isdir(os.path.join(sql_dir, d))
                                        and re.match(r'^\d{6}$', d)])
                    if db_versions > 0:
                        has_db = True
                snaps.append({
                    'date': entry,
                    'size': sz,
                    'has_files': has_files,
                    'has_db': has_db,
                    'db_versions': db_versions,
                })
        self._send_json(snaps)

    def _api_db_versions(self, path_info):
        """List all DB dump versions for a given hostname/snapshot.
        Returns the base sql/ dump plus any timestamped subdirs (HHMMSS/).
        Structure: /api/db-versions/<hostname>/<snapshot>
        """
        parts = path_info.split('/', 1)
        if len(parts) < 2:
            self._send_json({'error': 'Usage: /api/db-versions/<hostname>/<snapshot>'}, 400)
            return
        hostname, snap_date = parts[0], parts[1]
        sql_dir = os.path.join(backup_root(), hostname, snap_date, 'sql')
        if not os.path.isdir(sql_dir):
            self._send_json([])
            return

        versions = []

        # Check for base-level dump files (from full/daily backup)
        base_files = [f for f in os.listdir(sql_dir)
                      if os.path.isfile(os.path.join(sql_dir, f))]
        if base_files:
            total_size = '--'
            try:
                total_bytes = sum(os.path.getsize(os.path.join(sql_dir, f)) for f in base_files)
                if total_bytes < 1024:
                    total_size = f'{total_bytes}B'
                elif total_bytes < 1024 * 1024:
                    total_size = f'{total_bytes / 1024:.1f}K'
                elif total_bytes < 1024 * 1024 * 1024:
                    total_size = f'{total_bytes / (1024 * 1024):.1f}M'
                else:
                    total_size = f'{total_bytes / (1024 * 1024 * 1024):.1f}G'
            except Exception:
                pass
            # Get modification time of newest file as version timestamp
            newest = max(os.path.getmtime(os.path.join(sql_dir, f)) for f in base_files)
            versions.append({
                'version': 'base',
                'label': datetime.fromtimestamp(newest).strftime('%H:%M:%S'),
                'time': datetime.fromtimestamp(newest).strftime('%Y-%m-%d %H:%M:%S'),
                'size': total_size,
                'files': sorted([{'name': f, 'size': du_sh(os.path.join(sql_dir, f))}
                                 for f in base_files], key=lambda x: x['name']),
                'download_path': 'sql',
            })

        # Check for timestamped subdirs (HHMMSS from interval runs)
        for entry in sorted(os.listdir(sql_dir)):
            full = os.path.join(sql_dir, entry)
            if not os.path.isdir(full) or not re.match(r'^\d{6}$', entry):
                continue
            sub_files = [f for f in os.listdir(full)
                         if os.path.isfile(os.path.join(full, f))]
            if not sub_files:
                continue
            sub_size = du_sh(full)
            # Parse HHMMSS into readable time
            t_label = entry[:2] + ':' + entry[2:4] + ':' + entry[4:6]
            newest = max(os.path.getmtime(os.path.join(full, f)) for f in sub_files)
            versions.append({
                'version': entry,
                'label': t_label,
                'time': datetime.fromtimestamp(newest).strftime('%Y-%m-%d %H:%M:%S'),
                'size': sub_size,
                'files': sorted([{'name': f, 'size': du_sh(os.path.join(full, f))}
                                 for f in sub_files], key=lambda x: x['name']),
                'download_path': 'sql/' + entry,
            })

        self._send_json(versions)

    def _api_browse(self, browse_path):
        parts = browse_path.split('/', 2)
        if len(parts) < 2:
            self._send_json({'error': 'Invalid browse path'}, 400)
            return
        hostname = parts[0]
        snap_date = parts[1]
        sub_path = parts[2] if len(parts) > 2 else ''

        base_dir = os.path.join(backup_root(), hostname, snap_date)
        if sub_path.startswith('sql'):
            browse_dir = os.path.join(base_dir, sub_path)
            sub_path = ''
        elif sub_path:
            browse_dir = os.path.join(base_dir, 'files', sub_path)
        else:
            browse_dir = os.path.join(base_dir, 'files')

        if not os.path.isdir(base_dir):
            self._send_json({'error': f'Snapshot not found: {hostname}/{snap_date}'}, 404)
            return
        if not os.path.isdir(browse_dir):
            self._send_json({'error': 'Path not found'}, 404)
            return

        items = []
        try:
            for name in sorted(os.listdir(browse_dir)):
                full = os.path.join(browse_dir, name)
                ftype = 'dir' if os.path.isdir(full) else 'file'
                sz = du_sh(full)
                items.append({'name': name, 'type': ftype, 'size': sz})
        except PermissionError:
            pass

        rel_path = os.path.relpath(browse_dir, base_dir)
        self._send_json({
            'hostname': hostname,
            'snapshot': snap_date,
            'path': rel_path,
            'items': items,
        })

    def _api_download(self, dl_path, query):
        parts = dl_path.split('/', 2)
        if len(parts) < 2:
            self._send_json({'error': 'Invalid download path'}, 400)
            return
        hostname = parts[0]
        snap_date = parts[1]
        sub_path = parts[2] if len(parts) > 2 else 'files'

        dl_format = query.get('format', ['tar.gz'])[0]
        base_dir = os.path.join(backup_root(), hostname, snap_date)
        target_dir = os.path.join(base_dir, sub_path)

        if not os.path.exists(target_dir):
            self._send_json({'error': 'Path not found'}, 404)
            return

        base_name = f'{hostname}-{snap_date}-{os.path.basename(sub_path)}'
        tmp_archive = None
        try:
            if dl_format == 'zip':
                tmp_archive = f'/tmp/tm-download-{os.getpid()}.zip'
                subprocess.run(
                    ['zip', '-r', tmp_archive, os.path.basename(target_dir)],
                    cwd=os.path.dirname(target_dir), capture_output=True, timeout=300
                )
                self._send_download(tmp_archive, f'{base_name}.zip', 'application/zip')
            else:
                tmp_archive = f'/tmp/tm-download-{os.getpid()}.tar.gz'
                subprocess.run(
                    ['tar', '-czf', tmp_archive, '-C', os.path.dirname(target_dir), os.path.basename(target_dir)],
                    capture_output=True, timeout=300
                )
                self._send_download(tmp_archive, f'{base_name}.tar.gz', 'application/gzip')
        except Exception as e:
            self._send_json({'error': str(e)}, 500)
        finally:
            if tmp_archive and os.path.exists(tmp_archive):
                os.unlink(tmp_archive)

    def _api_backup_start(self, target_host, body_bytes):
        # Parse query params from the original URL
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        opts = ''
        if 'files-only' in query or 'files-only' in self.path:
            opts += ' --files-only'
        if 'db-only' in query or 'db-only' in self.path:
            opts += ' --db-only'

        ts = datetime.now().strftime('%Y-%m-%d_%H%M%S')
        logfile = os.path.join(log_dir(), f'backup-{target_host}-{ts}.log')
        script = os.path.join(SCRIPT_DIR, 'timemachine.sh')

        mode = 'full'
        if '--files-only' in opts:
            mode = 'files-only'
        elif '--db-only' in opts:
            mode = 'db-only'

        started = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        sf_path = os.path.join(state_dir(), f'proc-{target_host}-{ts}.state')

        def run_backup():
            try:
                env = os.environ.copy()
                env['_TM_BACKUP_LOGFILE'] = logfile
                with open(logfile, 'w') as lf:
                    cmd = f'{script} {target_host} --trigger api {opts}'.strip()
                    proc = subprocess.Popen(
                        cmd, shell=True, stdout=lf, stderr=lf, env=env,
                        start_new_session=True
                    )
                    # Update state file with the real subprocess PID
                    try:
                        with open(sf_path, 'w') as sf:
                            sf.write(f'{proc.pid}|{target_host}|{mode}|{started}|running|{logfile}')
                    except Exception:
                        pass

                    exit_code = proc.wait()
                    # Write exit code state
                    code_file = os.path.join(state_dir(), f'exit-{target_host}.code')
                    with open(code_file, 'w') as cf:
                        cf.write(str(exit_code))
                    # Update process state to completed/failed
                    try:
                        status = 'completed' if exit_code == 0 else 'failed'
                        with open(sf_path, 'w') as sf:
                            sf.write(f'{proc.pid}|{target_host}|{mode}|{started}|{status}|{logfile}')
                    except Exception:
                        pass
            except Exception:
                pass

        # Write initial state file (will be updated with real PID once subprocess starts)
        with open(sf_path, 'w') as f:
            f.write(f'0|{target_host}|{mode}|{started}|running|{logfile}')

        # Start in background thread
        t = threading.Thread(target=run_backup, daemon=True)
        t.start()

        self._send_json({
            'status': 'started',
            'hostname': target_host,
        })

    def _api_backup_all(self):
        """Trigger daily-runner.sh which handles priority, parallel jobs, reporting, and state."""
        runner = os.path.join(SCRIPT_DIR, 'daily-runner.sh')
        servers = read_servers_conf()
        max_jobs = int(env_val('TM_PARALLEL_JOBS', '5'))
        ts = datetime.now().strftime('%Y-%m-%d_%H%M%S')
        logfile = os.path.join(log_dir(), f'daily-manual-{ts}.log')

        def _run():
            try:
                with open(logfile, 'w') as lf:
                    subprocess.Popen(
                        runner, shell=True, stdout=lf, stderr=lf,
                        env=os.environ.copy(),
                        start_new_session=True
                    ).wait()
            except Exception:
                pass

        t = threading.Thread(target=_run, daemon=True)
        t.start()

        self._send_json({
            'status': 'started',
            'count': len(servers),
            'parallel_limit': max_jobs,
            'logfile': os.path.basename(logfile),
        })

    def _api_backup_kill(self, target_host):
        sd = state_dir()
        for sf in glob.glob(os.path.join(sd, f'proc-{target_host}-*.state')):
            try:
                content = open(sf).read().strip()
                parts = content.split('|')
                if len(parts) >= 6 and parts[4] == 'running':
                    pid = int(parts[0])
                    logfile = parts[5]
                    if pid > 0 and is_process_alive(pid):
                        # Log the kill event to the backup log
                        if logfile and os.path.isfile(logfile):
                            try:
                                ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                                with open(logfile, 'a') as lf:
                                    lf.write(f'\n[{ts}] [WARN ] Backup killed by user via dashboard (PID {pid})\n')
                            except Exception:
                                pass
                        os.kill(pid, signal.SIGTERM)
                        content = content.replace('|running|', '|killed|')
                        with open(sf, 'w') as f:
                            f.write(content)
                        self._send_json({'status': 'killed', 'hostname': target_host})
                        return
            except Exception:
                continue
        self._send_json({'error': f'No running process for {target_host}'}, 404)

    def _api_restore_start(self, target_host, body_bytes):
        data = parse_json_body(body_bytes)
        snap_date = data.get('snapshot', '')
        if not snap_date:
            self._send_json({'error': 'snapshot date is required'}, 400)
            return

        rest_path = data.get('path', '')
        rest_target = data.get('target', '')
        rest_mode = data.get('mode', '')
        rest_format = data.get('format', '')

        opts = f'--date {snap_date} --no-confirm'
        if rest_path:
            opts += f' --path {rest_path}'
        if rest_target:
            opts += f' --target {rest_target}'
        if rest_format:
            opts += f' --format {rest_format}'
        if rest_mode == 'files-only':
            opts += ' --files-only'
        elif rest_mode == 'db-only':
            opts += ' --db-only'

        ts = datetime.now().strftime('%Y-%m-%d_%H%M%S')
        logfile = os.path.join(log_dir(), f'restore-{target_host}-{ts}.log')
        script = os.path.join(SCRIPT_DIR, 'restore.sh')

        started = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        rest_desc = snap_date
        if rest_path:
            rest_desc += f' {rest_path}'
        if rest_target:
            rest_desc += f' -> {rest_target}'

        state_file = os.path.join(state_dir(), f'restore-{target_host}-{ts}.state')

        def run_restore():
            try:
                with open(logfile, 'w') as lf:
                    cmd = f'{script} {target_host} {opts}'.strip()
                    proc = subprocess.Popen(cmd, shell=True, stdout=lf, stderr=lf)
                    exit_code = proc.wait()
                    status = 'completed' if exit_code == 0 else 'failed'
                    try:
                        content = open(state_file).read()
                        content = content.replace('|running|', f'|{status}|')
                        with open(state_file, 'w') as f:
                            f.write(content)
                    except Exception:
                        pass
            except Exception:
                pass

        t = threading.Thread(target=run_restore, daemon=True)
        t.start()

        # Write initial state
        pid = os.getpid()
        with open(state_file, 'w') as f:
            f.write(f'{pid}|{target_host}|{rest_desc}|{started}|running|{logfile}')

        self._send_json({
            'status': 'started',
            'hostname': target_host,
            'pid': pid,
            'snapshot': snap_date,
            'logfile': os.path.basename(logfile),
        })

    def _api_restores_list(self):
        sd = state_dir()
        restores = []
        cutoff = datetime.now() - timedelta(days=30)

        files = sorted(glob.glob(os.path.join(sd, 'restore-*.state')),
                       key=os.path.getmtime, reverse=True)
        for sf in files:
            try:
                content = open(sf).read().strip()
                parts = content.split('|')
                if len(parts) < 6:
                    continue
                pid, hostname, desc, started, status, logfile = (
                    parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
                )

                # Filter by date
                try:
                    started_dt = datetime.strptime(started, '%Y-%m-%d %H:%M:%S')
                    if started_dt < cutoff:
                        continue
                except ValueError:
                    pass

                # Check if running process is still alive
                if status == 'running' and not is_process_alive(pid):
                    # Check log for errors
                    if logfile and os.path.isfile(logfile):
                        log_tail = tail_file(logfile, 30)
                        if re.search(r'\[ERROR\s*\]', log_tail):
                            status = 'failed'
                        else:
                            status = 'completed'
                    else:
                        status = 'completed'
                    content = content.replace('|running|', f'|{status}|')
                    with open(sf, 'w') as f:
                        f.write(content)

                rid = os.path.basename(sf).replace('.state', '')
                restores.append({
                    'id': rid,
                    'pid': int(pid) if pid.isdigit() else 0,
                    'hostname': hostname,
                    'description': desc,
                    'started': started,
                    'status': status,
                    'logfile': os.path.basename(logfile) if logfile else '',
                })
            except Exception:
                continue
        self._send_json(restores)

    def _api_restores_clear(self):
        sd = state_dir()
        cleared = 0
        for sf in glob.glob(os.path.join(sd, 'restore-*.state')):
            try:
                content = open(sf).read().strip()
                parts = content.split('|')
                if len(parts) >= 5:
                    status = parts[4]
                    pid = parts[0]
                    if status == 'running' and is_process_alive(pid):
                        continue
                os.unlink(sf)
                cleared += 1
            except Exception:
                continue
        self._send_json({'status': 'cleared', 'count': cleared})

    def _api_restore_delete(self, restore_id):
        sd = state_dir()
        for sf in glob.glob(os.path.join(sd, 'restore-*.state')):
            sf_base = os.path.basename(sf).replace('.state', '')
            if sf_base == restore_id:
                try:
                    content = open(sf).read().strip()
                    parts = content.split('|')
                    if len(parts) >= 5:
                        status = parts[4]
                        pid = parts[0]
                        if status == 'running' and is_process_alive(pid):
                            self._send_json({'error': 'Cannot delete a running restore task'}, 409)
                            return
                        logfile = parts[5] if len(parts) > 5 else ''
                        os.unlink(sf)
                        if logfile and os.path.isfile(logfile):
                            os.unlink(logfile)
                    self._send_json({'status': 'deleted'})
                except Exception as e:
                    self._send_json({'error': str(e)}, 500)
                return
        self._send_json({'error': 'Restore task not found'}, 404)

    def _api_restore_log(self, log_name):
        logfile = os.path.join(log_dir(), log_name)
        if not os.path.isfile(logfile):
            self._send_json({'error': f'Log file not found: {log_name}'}, 404)
            return

        content = tail_file(logfile, 500)
        is_running = False
        sd = state_dir()
        for sf in glob.glob(os.path.join(sd, 'restore-*.state')):
            try:
                data = open(sf).read().strip()
                parts = data.split('|')
                if len(parts) >= 6:
                    sf_log = os.path.basename(parts[5])
                    sf_status = parts[4]
                    sf_pid = parts[0]
                    if sf_log == log_name and sf_status == 'running' and is_process_alive(sf_pid):
                        is_running = True
                        break
            except Exception:
                continue

        self._send_json({
            'logfile': log_name,
            'lines': content,
            'running': is_running,
        })

    def _api_servers_list(self):
        self._send_json(read_servers_conf())

    def _api_servers_add(self, body_bytes):
        data = parse_json_body(body_bytes)
        hostname = data.get('hostname', '').strip()
        opts = data.get('options', '').strip()

        if not hostname:
            self._send_json({'error': 'hostname is required'}, 400)
            return

        conf = os.path.join(project_root(), 'config', 'servers.conf')
        os.makedirs(os.path.dirname(conf), exist_ok=True)

        # Check duplicates
        if os.path.isfile(conf):
            with open(conf) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        if line.split()[0] == hostname:
                            self._send_json({'error': f"Server '{hostname}' already exists"}, 409)
                            return

        entry = f'{hostname} {opts}'.strip() if opts else hostname
        with open(conf, 'a') as f:
            f.write(entry + '\n')

        # Initialize interval timestamps so scheduler doesn't trigger immediately
        sd = state_dir()
        now = str(int(time.time()))
        if '--backup-interval' in opts:
            with open(os.path.join(sd, f'last-backup-{hostname}'), 'w') as f:
                f.write(now)
        if '--db-interval' in opts:
            with open(os.path.join(sd, f'last-db-{hostname}'), 'w') as f:
                f.write(now)

        # Write skip marker so the daily runner won't auto-include this server today.
        # The user is asked separately (via web confirm or CLI prompt) whether to start now.
        import datetime
        today = datetime.date.today().strftime('%Y-%m-%d')
        with open(os.path.join(sd, f'skip-daily-{hostname}'), 'w') as f:
            f.write(today)

        self._send_json({'status': 'added', 'hostname': hostname, 'options': opts}, 201)

    def _api_servers_update(self, target_host, body_bytes):
        data = parse_json_body(body_bytes)
        conf = os.path.join(project_root(), 'config', 'servers.conf')

        if not os.path.isfile(conf):
            self._send_json({'error': 'No servers.conf found'}, 404)
            return

        lines = open(conf).readlines()
        found = False
        new_lines = []

        # Build new options
        opts_parts = []
        prio = data.get('priority')
        if prio is not None:
            opts_parts.append(f'--priority {prio}')
        db_int = data.get('db_interval')
        if db_int and int(db_int) > 0:
            opts_parts.append(f'--db-interval {db_int}h')
        bk_int = data.get('backup_interval')
        if bk_int and int(bk_int) > 0:
            opts_parts.append(f'--backup-interval {bk_int}h')
        mode = data.get('mode', '')
        if mode == 'files-only':
            opts_parts.append('--files-only')
        elif mode == 'db-only':
            opts_parts.append('--db-only')
        if data.get('no_rotate') is True:
            opts_parts.append('--no-rotate')
        notify = data.get('notify_email', '')
        if notify:
            opts_parts.append(f'--notify {notify}')
        opts = ' '.join(opts_parts)
        new_entry = f'{target_host} {opts}'.strip() if opts else target_host

        for line in lines:
            stripped = line.strip()
            if stripped and not stripped.startswith('#') and stripped.split()[0] == target_host:
                new_lines.append(new_entry + '\n')
                found = True
            else:
                new_lines.append(line)

        if not found:
            self._send_json({'error': f"Server '{target_host}' not found"}, 404)
            return

        with open(conf, 'w') as f:
            f.writelines(new_lines)

        # Reset interval timestamps to "now" so the scheduler waits the
        # full interval before triggering. Without this, changing an interval
        # setting would cause an immediate backup.
        sd = state_dir()
        now = str(int(datetime.now().timestamp()))
        if db_int and int(db_int) > 0:
            with open(os.path.join(sd, f'last-db-{target_host}'), 'w') as f:
                f.write(now)
        if bk_int and int(bk_int) > 0:
            with open(os.path.join(sd, f'last-backup-{target_host}'), 'w') as f:
                f.write(now)

        self._send_json({'status': 'updated', 'hostname': target_host, 'options': opts})

    def _api_servers_delete(self, target_host):
        conf = os.path.join(project_root(), 'config', 'servers.conf')
        if not os.path.isfile(conf):
            self._send_json({'error': 'No servers.conf found'}, 404)
            return

        lines = open(conf).readlines()
        new_lines = []
        found = False
        for line in lines:
            stripped = line.strip()
            if stripped and not stripped.startswith('#') and stripped.split()[0] == target_host:
                found = True
            else:
                new_lines.append(line)

        if not found:
            self._send_json({'error': f"Server '{target_host}' not found"}, 404)
            return

        with open(conf, 'w') as f:
            f.writelines(new_lines)

        self._send_json({'status': 'removed', 'hostname': target_host})

    def _api_servers_archive(self, target_host):
        result = archive_server(target_host)
        if result is None:
            self._send_json({'error': f"Server '{target_host}' not found in servers.conf"}, 404)
            return
        self._send_json({'status': 'archived', 'hostname': target_host})

    def _api_servers_full_delete(self, target_host):
        # Remove from servers.conf
        conf = os.path.join(project_root(), 'config', 'servers.conf')
        if os.path.isfile(conf):
            lines = open(conf).readlines()
            new_lines = [l for l in lines if not (l.strip() and not l.strip().startswith('#') and l.strip().split()[0] == target_host)]
            with open(conf, 'w') as f:
                f.writelines(new_lines)
        # Also remove from archived.conf if present
        archived_conf = os.path.join(project_root(), 'config', 'archived.conf')
        if os.path.isfile(archived_conf):
            lines = open(archived_conf).readlines()
            new_lines = [l for l in lines if not (l.strip() and not l.strip().startswith('#') and l.strip().split()[0] == target_host)]
            with open(archived_conf, 'w') as f:
                f.writelines(new_lines)
        # Remove per-server exclude file
        excl = os.path.join(project_root(), 'config', f'exclude.{target_host}.conf')
        if os.path.isfile(excl):
            os.remove(excl)
        # Delete backup data in background
        delete_server_data_bg(target_host)
        self._send_json({'status': 'deleting', 'hostname': target_host,
                         'message': 'Server removed. Backup data is being deleted in the background.'})

    def _api_archived_list(self):
        archived = read_archived_conf()
        delete_tasks = get_delete_tasks()
        self._send_json({'servers': archived, 'delete_tasks': delete_tasks})

    def _api_archived_unarchive(self, hostname):
        result = unarchive_server(hostname)
        if result is None:
            self._send_json({'error': f"Server '{hostname}' not found in archive"}, 404)
            return
        self._send_json({'status': 'unarchived', 'hostname': hostname})

    def _api_archived_delete(self, hostname):
        # Remove from archived.conf
        archived_conf = os.path.join(project_root(), 'config', 'archived.conf')
        if os.path.isfile(archived_conf):
            lines = open(archived_conf).readlines()
            new_lines = [l for l in lines if not (l.strip() and not l.strip().startswith('#') and l.strip().split()[0] == hostname)]
            with open(archived_conf, 'w') as f:
                f.writelines(new_lines)
        # Remove per-server exclude file
        excl = os.path.join(project_root(), 'config', f'exclude.{hostname}.conf')
        if os.path.isfile(excl):
            os.remove(excl)
        # Delete backup data in background
        delete_server_data_bg(hostname)
        self._send_json({'status': 'deleting', 'hostname': hostname,
                         'message': 'Archived server removed. Backup data is being deleted in the background.'})

    def _api_settings_get(self):
        self._send_json({
            'schedule_hour': int(env_val('TM_SCHEDULE_HOUR', '11')),
            'schedule_minute': int(env_val('TM_SCHEDULE_MINUTE', '0')),
            'retention_days': int(env_val('TM_RETENTION_DAYS', '7')),
            'parallel_jobs': int(env_val('TM_PARALLEL_JOBS', '5')),
            'alert_enabled': env_val('TM_ALERT_ENABLED', 'false'),
            'alert_email': env_val('TM_ALERT_EMAIL', ''),
            'notify_backup_ok': env_val('TM_NOTIFY_BACKUP_OK', 'true'),
            'notify_backup_fail': env_val('TM_NOTIFY_BACKUP_FAIL', 'true'),
            'notify_restore_ok': env_val('TM_NOTIFY_RESTORE_OK', 'true'),
            'notify_restore_fail': env_val('TM_NOTIFY_RESTORE_FAIL', 'true'),
            'alert_email_backup_ok': env_val('TM_ALERT_EMAIL_BACKUP_OK', ''),
            'alert_email_backup_fail': env_val('TM_ALERT_EMAIL_BACKUP_FAIL', ''),
            'alert_email_restore_ok': env_val('TM_ALERT_EMAIL_RESTORE_OK', ''),
            'alert_email_restore_fail': env_val('TM_ALERT_EMAIL_RESTORE_FAIL', ''),
            'smtp_host': env_val('TM_SMTP_HOST', ''),
            'smtp_port': int(env_val('TM_SMTP_PORT', '587')),
            'smtp_user': env_val('TM_SMTP_USER', ''),
            'smtp_pass': env_val('TM_SMTP_PASS', ''),
            'smtp_from': env_val('TM_SMTP_FROM', ''),
            'smtp_tls': env_val('TM_SMTP_TLS', 'true'),
        })

    def _api_settings_put(self, body_bytes):
        data = parse_json_body(body_bytes)
        key_map = {
            'schedule_hour': 'TM_SCHEDULE_HOUR',
            'schedule_minute': 'TM_SCHEDULE_MINUTE',
            'retention_days': 'TM_RETENTION_DAYS',
            'parallel_jobs': 'TM_PARALLEL_JOBS',
            'alert_enabled': 'TM_ALERT_ENABLED',
            'alert_email': 'TM_ALERT_EMAIL',
            'notify_backup_ok': 'TM_NOTIFY_BACKUP_OK',
            'notify_backup_fail': 'TM_NOTIFY_BACKUP_FAIL',
            'notify_restore_ok': 'TM_NOTIFY_RESTORE_OK',
            'notify_restore_fail': 'TM_NOTIFY_RESTORE_FAIL',
            'alert_email_backup_ok': 'TM_ALERT_EMAIL_BACKUP_OK',
            'alert_email_backup_fail': 'TM_ALERT_EMAIL_BACKUP_FAIL',
            'alert_email_restore_ok': 'TM_ALERT_EMAIL_RESTORE_OK',
            'alert_email_restore_fail': 'TM_ALERT_EMAIL_RESTORE_FAIL',
            'smtp_host': 'TM_SMTP_HOST',
            'smtp_port': 'TM_SMTP_PORT',
            'smtp_user': 'TM_SMTP_USER',
            'smtp_pass': 'TM_SMTP_PASS',
            'smtp_from': 'TM_SMTP_FROM',
            'smtp_tls': 'TM_SMTP_TLS',
        }
        for json_key, env_key in key_map.items():
            if json_key in data:
                env_set(env_key, str(data[json_key]))

        # Signal scheduler to reload
        sd = state_dir()
        try:
            Path(os.path.join(sd, '.reload_config')).touch()
        except Exception:
            pass

        reload_config()
        self._send_json({'status': 'saved'})

    def _api_test_email(self, body_bytes):
        """Send a test email via SMTP to verify configuration."""
        import smtplib
        from email.mime.text import MIMEText

        data = parse_json_body(body_bytes) if body_bytes else {}
        smtp_host = data.get('smtp_host', env_val('TM_SMTP_HOST', ''))
        smtp_port = int(data.get('smtp_port', env_val('TM_SMTP_PORT', '587')))
        smtp_user = data.get('smtp_user', env_val('TM_SMTP_USER', ''))
        smtp_pass = data.get('smtp_pass', env_val('TM_SMTP_PASS', ''))
        smtp_from = data.get('smtp_from', env_val('TM_SMTP_FROM', '')) or smtp_user
        smtp_tls = str(data.get('smtp_tls', env_val('TM_SMTP_TLS', 'true')))
        recipient = data.get('recipient', env_val('TM_ALERT_EMAIL', ''))

        if not smtp_host:
            self._send_json({'error': 'SMTP host not configured'}, 400)
            return
        if not recipient:
            self._send_json({'error': 'No recipient email address'}, 400)
            return
        if not smtp_from:
            self._send_json({'error': 'No sender (From) address configured'}, 400)
            return

        hostname = get_hostname()
        msg = MIMEText(f'This is a test email from TimeMachine Backup on {hostname}.\n\n'
                       f'If you received this, your SMTP configuration is working correctly.\n\n'
                       f'SMTP Host: {smtp_host}\n'
                       f'SMTP Port: {smtp_port}\n'
                       f'TLS: {smtp_tls}\n')
        msg['Subject'] = f'[TimeMachine] Test email from {hostname}'
        msg['From'] = smtp_from
        msg['To'] = recipient

        try:
            if smtp_port == 465:
                s = smtplib.SMTP_SSL(smtp_host, smtp_port, timeout=15)
            else:
                s = smtplib.SMTP(smtp_host, smtp_port, timeout=15)
                if smtp_tls == 'true':
                    s.starttls()
            if smtp_user and smtp_pass:
                s.login(smtp_user, smtp_pass)
            s.sendmail(smtp_from, [r.strip() for r in recipient.split(',')], msg.as_string())
            s.quit()
            self._send_json({'status': 'sent', 'recipient': recipient})
        except Exception as e:
            self._send_json({'error': f'SMTP failed: {e}'}, 500)

    def _api_ssh_key(self):
        key_file = CONFIG.get('ssh_key', '') + '.pub'
        if os.path.isfile(key_file):
            key_content = open(key_file).read().strip()
            self._send_json({
                'ssh_public_key': key_content,
                'hostname': get_hostname(),
            })
        else:
            self._send_json({'error': 'SSH public key not found'}, 404)

    def _api_ssh_key_raw(self):
        key_file = CONFIG.get('ssh_key', '') + '.pub'
        if os.path.isfile(key_file):
            self._send_text(open(key_file).read().strip())
        else:
            self._send_text('SSH public key not found', status=404)

    def _api_logs(self, target_host):
        ld = log_dir()
        # Find latest log
        logs = sorted(glob.glob(os.path.join(ld, f'backup-{target_host}-*.log')),
                       key=os.path.getmtime, reverse=True)
        logfile = logs[0] if logs else os.path.join(ld, f'service-{target_host}.log')

        if not os.path.isfile(logfile):
            self._send_json({'error': f'No logs for {target_host}'}, 404)
            return

        content = tail_file(logfile, 500)
        log_name = os.path.basename(logfile)

        # Check if backup is running
        is_running = False
        sd = state_dir()
        for sf in glob.glob(os.path.join(sd, f'proc-{target_host}-*.state')):
            try:
                data = open(sf).read().strip()
                parts = data.split('|')
                if len(parts) >= 5 and parts[4] == 'running':
                    if parts[0] == '0' or is_process_alive(parts[0]):
                        is_running = True
                        break
            except Exception:
                continue

        # Available log files
        available = [os.path.basename(l) for l in logs[:30]]

        self._send_json({
            'hostname': target_host,
            'logfile': log_name,
            'lines': content,
            'running': is_running,
            'available': available,
        })

    def _api_rsync_log(self, target_host):
        """Return the latest rsync transfer log for a host."""
        ld = log_dir()
        logs = sorted(glob.glob(os.path.join(ld, f'rsync-{target_host}-*.log')),
                       key=os.path.getmtime, reverse=True)
        if not logs:
            self._send_json({'error': f'No rsync logs for {target_host}'}, 404)
            return

        logfile = logs[0]
        content = tail_file(logfile, 1000)
        log_name = os.path.basename(logfile)

        # Check if backup is currently running (rsync log is being written)
        is_running = False
        sd = state_dir()
        for sf in glob.glob(os.path.join(sd, f'proc-{target_host}*.state')):
            try:
                data = open(sf).read().strip()
                parts = data.split('|')
                if len(parts) >= 5 and parts[4] == 'running':
                    if parts[0] == '0' or is_process_alive(parts[0]):
                        is_running = True
                        break
            except Exception:
                continue

        available = [os.path.basename(l) for l in logs[:30]]

        self._send_json({
            'hostname': target_host,
            'logfile': log_name,
            'lines': content,
            'running': is_running,
            'available': available,
        })

    def _api_system(self):
        # Load averages
        load1 = load5 = load15 = '0'
        try:
            with open('/proc/loadavg') as f:
                parts = f.read().split()
                load1, load5, load15 = parts[0], parts[1], parts[2]
        except Exception:
            pass

        # CPU count
        cpu_count = 1
        try:
            cpu_count = os.cpu_count() or 1
        except Exception:
            pass

        # Memory
        mem_total = mem_used = mem_avail = mem_pct = 0
        try:
            with open('/proc/meminfo') as f:
                meminfo = {}
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        meminfo[parts[0].rstrip(':')] = int(parts[1])
                mem_total = meminfo.get('MemTotal', 0) // 1024
                mem_avail = meminfo.get('MemAvailable', 0) // 1024
                mem_used = mem_total - mem_avail
                mem_pct = (mem_used * 100 // mem_total) if mem_total > 0 else 0
        except Exception:
            pass

        # OS info
        os_name = 'Unknown'
        try:
            with open('/etc/os-release') as f:
                for line in f:
                    if line.startswith('PRETTY_NAME='):
                        os_name = line.split('=', 1)[1].strip().strip('"')
                        break
        except Exception:
            pass

        kernel = ''
        try:
            kernel = subprocess.check_output(['uname', '-r'], text=True, timeout=5).strip()
        except Exception:
            pass

        sys_uptime = 0
        try:
            with open('/proc/uptime') as f:
                sys_uptime = int(float(f.read().split()[0]))
        except Exception:
            pass

        self._send_json({
            'load1': load1,
            'load5': load5,
            'load15': load15,
            'cpu_count': cpu_count,
            'mem_total': mem_total,
            'mem_used': mem_used,
            'mem_available': mem_avail,
            'mem_percent': mem_pct,
            'os': os_name,
            'kernel': kernel,
            'sys_uptime': sys_uptime,
        })

    def _api_failures(self):
        ld = log_dir()
        failures = []
        seen_hosts = set()

        # Check per-backup logs
        logs = sorted(glob.glob(os.path.join(ld, 'backup-*.log')),
                       key=os.path.getmtime, reverse=True)[:50]
        for logfile in logs:
            lname = os.path.basename(logfile).replace('.log', '')
            # Extract hostname: backup-<hostname>-<timestamp>
            m = re.match(r'^backup-(.+)-\d{4}-\d{2}-\d{2}_\d{6}$', lname)
            if not m:
                continue
            lhost = m.group(1)
            if lhost in seen_hosts:
                continue
            seen_hosts.add(lhost)

            # Extract timestamp
            ts_match = re.search(r'(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})(\d{2})$', lname)
            log_ts = ''
            if ts_match:
                log_ts = f'{ts_match.group(1)} {ts_match.group(2)}:{ts_match.group(3)}:{ts_match.group(4)}'

            # Check for errors
            log_tail = tail_file(logfile, 50)
            for fline in log_tail.splitlines():
                if re.search(r'\[ERROR\]|FAIL|fatal|Permission denied|cannot create', fline, re.IGNORECASE):
                    line_ts_m = re.match(r'^\[?(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]?', fline)
                    line_ts = line_ts_m.group(1) if line_ts_m else log_ts
                    failures.append({
                        'hostname': lhost,
                        'message': fline.strip(),
                        'logfile': os.path.basename(logfile),
                        'timestamp': line_ts,
                    })

        self._send_json(failures)

    def _api_history(self):
        servers = read_servers_conf()
        history = []
        ld = log_dir()
        br = backup_root()

        for srv in servers:
            hostname = srv['hostname']
            snap_dir = os.path.join(br, hostname)
            last_backup = 'never'
            last_backup_time = ''
            snap_count = 0
            total_size = '0'

            if os.path.isdir(snap_dir):
                snapshots = [d for d in os.listdir(snap_dir)
                             if os.path.isdir(os.path.join(snap_dir, d)) and re.match(r'^\d{4}-\d{2}-\d{2}(_\d{6})?$', d)]
                legacy_snaps = [d for d in os.listdir(snap_dir)
                                if os.path.isdir(os.path.join(snap_dir, d)) and re.match(r'^daily\.\d{4}-\d{2}-\d{2}$', d)]
                # Count unique dates (YYYY-MM-DD) across current and legacy formats
                all_dates = set(s[:10] for s in snapshots)
                all_dates.update(s[6:] for s in legacy_snaps)
                snap_count = len(all_dates)
                all_snaps = snapshots + legacy_snaps
                if all_snaps:
                    last_backup = sorted(all_snaps)[-1]
                total_size = du_sh(snap_dir)

            # Check last backup status
            last_status = 'ok'
            logs = sorted(glob.glob(os.path.join(ld, f'backup-{hostname}-*.log')),
                           key=os.path.getmtime, reverse=True)
            latest_log = logs[0] if logs else os.path.join(ld, f'service-{hostname}.log')
            # 1. Check exit code file first (most reliable)
            exit_file = os.path.join(state_dir(), f'exit-{hostname}.code')
            if os.path.isfile(exit_file):
                try:
                    ec = open(exit_file).read().strip()
                    if ec and ec != '0':
                        last_status = 'error'
                except Exception:
                    pass
            # 2. Scan entire log for [ERROR] markers
            if last_status != 'error' and os.path.isfile(latest_log):
                try:
                    log_content = open(latest_log).read()
                    if re.search(r'\[ERROR\s*\]', log_content):
                        last_status = 'error'
                except Exception:
                    pass
            if os.path.isfile(latest_log):
                # Extract timestamp
                log_bn = os.path.basename(latest_log).replace('.log', '')
                ts_m = re.search(r'(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})(\d{2})$', log_bn)
                if ts_m:
                    last_backup_time = f'{ts_m.group(1)} {ts_m.group(2)}:{ts_m.group(3)}:{ts_m.group(4)}'

            history.append({
                'hostname': hostname,
                'last_backup': last_backup,
                'last_backup_time': last_backup_time,
                'snapshots': snap_count,
                'total_size': total_size,
                'status': last_status,
            })

        self._send_json(history)

    def _api_excludes_get(self, hostname=None):
        config_dir = os.path.join(project_root(), 'config')
        if hostname:
            filepath = os.path.join(config_dir, f'exclude.{hostname}.conf')
        else:
            filepath = os.path.join(config_dir, 'exclude.conf')
        content = ''
        if os.path.isfile(filepath):
            try:
                content = open(filepath).read()
            except Exception:
                pass
        self._send_json({
            'hostname': hostname or '__global__',
            'content': content,
            'path': filepath,
        })

    def _api_excludes_put(self, body_bytes, hostname=None):
        data = parse_json_body(body_bytes)
        content = data.get('content', '')
        config_dir = os.path.join(project_root(), 'config')
        if hostname:
            filepath = os.path.join(config_dir, f'exclude.{hostname}.conf')
        else:
            filepath = os.path.join(config_dir, 'exclude.conf')
        try:
            os.makedirs(config_dir, exist_ok=True)
            with open(filepath, 'w') as f:
                f.write(content)
            self._send_json({'status': 'saved', 'path': filepath})
        except Exception as e:
            self._send_json({'error': str(e)}, 500)

    def _api_disk(self):
        br = backup_root()
        try:
            result = subprocess.run(['df', '-h', br], capture_output=True, text=True, timeout=10)
            lines = result.stdout.strip().splitlines()
            if len(lines) >= 2:
                # Handle wrapped output: long filesystem names cause df to
                # split into 3+ lines. Join all non-header lines and re-split.
                data_line = ' '.join(lines[1:])
                parts = data_line.split()
                # Standard df columns: Filesystem Size Used Avail Use% Mounted
                # With 6 parts: index 0=fs, 1=size, 2=used, 3=avail, 4=pct, 5=mount
                # With 5 parts (no fs on wrapped line): 0=size, 1=used, 2=avail, 3=pct, 4=mount
                if len(parts) >= 6:
                    total, used, avail, pct_s, mount = parts[1], parts[2], parts[3], parts[4], parts[5]
                elif len(parts) == 5:
                    total, used, avail, pct_s, mount = parts[0], parts[1], parts[2], parts[3], parts[4]
                else:
                    raise ValueError(f'Unexpected df output: {data_line}')
                pct = int(pct_s.rstrip('%')) if pct_s.rstrip('%').isdigit() else 0
                self._send_json({
                    'total': total,
                    'used': used,
                    'available': avail,
                    'percent': pct,
                    'mount': mount,
                    'path': br,
                })
                return
        except Exception as e:
            import logging
            logging.warning('Disk API error: %s', e)
        self._send_json({'total': '--', 'used': '--', 'available': '--', 'percent': 0, 'mount': br, 'path': br})


def _reconcile_state_files(sd):
    """Check state files for 'running' entries and verify PIDs are alive.
    Mark dead ones as failed so the dashboard shows correct status after restart.
    Also detect orphaned backup processes that have no state file."""
    # 1. Check existing state files
    for sf in glob.glob(os.path.join(sd, 'proc-*.state')):
        try:
            content = open(sf).read().strip()
            parts = content.split('|')
            if len(parts) < 6:
                continue
            pid_str, hostname, mode, started, status, logfile = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
            if status != 'running':
                continue
            pid = int(pid_str) if pid_str.isdigit() else 0
            alive = False
            if pid > 0:
                try:
                    os.kill(pid, 0)
                    alive = True
                except OSError:
                    pass
            if alive:
                print(f'Reconcile: {hostname} (PID {pid}) still running — keeping', flush=True)
            else:
                print(f'Reconcile: {hostname} (PID {pid}) is dead — marking failed', flush=True)
                with open(sf, 'w') as f:
                    f.write(f'{pid_str}|{hostname}|{mode}|{started}|failed|{logfile}')
                code_file = os.path.join(sd, f'exit-{hostname}.code')
                if not os.path.exists(code_file):
                    with open(code_file, 'w') as cf:
                        cf.write('137')
        except Exception:
            pass

    # 2. Detect orphaned backup processes (running timemachine.sh with no state file)
    try:
        result = subprocess.run(['ps', '-eo', 'pid,args'],
                                capture_output=True, text=True, timeout=5)
        for line in result.stdout.strip().splitlines():
            if 'timemachine.sh' not in line or '--trigger' not in line:
                continue
            line = line.strip()
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid_str = parts[0]
            cmdline = parts[1]
            # Extract hostname (first arg after timemachine.sh)
            m = re.search(r'timemachine\.sh\s+(\S+)', cmdline)
            if not m:
                continue
            host = m.group(1)
            # Skip if we already have a running state file for this hostname
            sf_path = os.path.join(sd, f'proc-{host}.state')
            if os.path.isfile(sf_path):
                try:
                    sf_status = open(sf_path).read().strip().split('|')[4]
                    if sf_status == 'running':
                        continue
                except Exception:
                    pass
            mode = 'full'
            if '--files-only' in cmdline:
                mode = 'files-only'
            elif '--db-only' in cmdline:
                mode = 'db-only'
            ld = log_dir()
            logfile = ''
            try:
                logs = sorted(glob.glob(os.path.join(ld, f'backup-{host}-*.log')), reverse=True)
                if logs:
                    logfile = logs[0]
            except Exception:
                pass
            started = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            print(f'Reconcile: found orphan backup for {host} (PID {pid_str}) — re-registering', flush=True)
            with open(sf_path, 'w') as f:
                f.write(f'{pid_str}|{host}|{mode}|{started}|running|{logfile}')
    except Exception:
        pass


# ============================================================
# MAIN
# ============================================================

def main():
    global CONFIG, SCRIPT_DIR, SERVICE_START_TIME
    import argparse

    parser = argparse.ArgumentParser(description='TimeMachine API Server')
    parser.add_argument('--bind', default='0.0.0.0', help='Bind address')
    parser.add_argument('--port', type=int, default=7600, help='Port')
    parser.add_argument('--project-root', default='', help='Project root directory')
    args = parser.parse_args()

    # Determine project root
    pr = args.project_root
    if not pr:
        pr = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    SCRIPT_DIR = os.path.join(pr, 'bin')

    CONFIG.update(get_config(pr))
    SERVICE_START_TIME = int(time.time())

    # Ensure state directory exists
    sd = state_dir()
    os.makedirs(sd, exist_ok=True)

    # Reconcile stale state files: check if "running" PIDs are still alive
    _reconcile_state_files(sd)

    server = ThreadedHTTPServer((args.bind, args.port), APIHandler)
    print(f'TimeMachine API server listening on {args.bind}:{args.port}', flush=True)

    # Hard shutdown — os._exit() kills the process immediately without
    # waiting for threads, socket close, or atexit handlers.
    def shutdown_handler(signum, frame):
        print('Shutting down API server...', flush=True)
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
