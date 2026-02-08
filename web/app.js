/* ============================================================
   TimeMachine Backup - Dashboard JavaScript
   ============================================================ */

const API_BASE = window.location.origin;
const REFRESH_INTERVAL = 10000;

/* ============================================================
   API HELPERS
   ============================================================ */

var _apiErrors = 0;

async function apiGet(endpoint) {
    try {
        const resp = await fetch(`${API_BASE}${endpoint}`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status} ${resp.statusText}`);
        const text = await resp.text();
        if (!text) return null;
        _apiErrors = 0;
        return JSON.parse(text);
    } catch (e) {
        _apiErrors++;
        console.error(`API GET ${endpoint}:`, e.message);
        if (_apiErrors === 3) {
            toast('API unreachable: ' + e.message + ' — check if the TimeMachine service is running', 'error');
        }
        return null;
    }
}

async function apiPost(endpoint, body) {
    try {
        const opts = { method: 'POST' };
        if (body) {
            opts.headers = { 'Content-Type': 'application/json' };
            opts.body = JSON.stringify(body);
        }
        const resp = await fetch(`${API_BASE}${endpoint}`, opts);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        return await resp.json();
    } catch (e) {
        console.error(`API POST ${endpoint}:`, e);
        return null;
    }
}

async function apiDelete(endpoint) {
    try {
        const resp = await fetch(`${API_BASE}${endpoint}`, { method: 'DELETE' });
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        return await resp.json();
    } catch (e) {
        console.error(`API DELETE ${endpoint}:`, e);
        return null;
    }
}

/* ============================================================
   TOAST NOTIFICATIONS
   ============================================================ */

function toast(message, type) {
    type = type || 'info';
    const container = document.getElementById('toast-container');
    const el = document.createElement('div');
    el.className = 'toast toast-' + type;
    el.textContent = message;
    container.appendChild(el);
    setTimeout(function() {
        el.style.opacity = '0';
        el.style.transform = 'translateX(1rem)';
        el.style.transition = '0.3s ease';
        setTimeout(function() { el.remove(); }, 300);
    }, 3500);
}

/* ============================================================
   MODAL
   ============================================================ */

function openModal(title, html) {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').innerHTML = html;
    document.getElementById('modal-overlay').classList.remove('hidden');
}

function closeModal(e) {
    if (e && e.target !== e.currentTarget) return;
    document.getElementById('modal-overlay').classList.add('hidden');
}

/* ============================================================
   STATUS
   ============================================================ */

function formatUptime(seconds) {
    var days = Math.floor(seconds / 86400);
    var hours = Math.floor((seconds % 86400) / 3600);
    var mins = Math.floor((seconds % 3600) / 60);
    if (days > 0) return days + 'd ' + hours + 'h ' + mins + 'm';
    if (hours > 0) return hours + 'h ' + mins + 'm';
    return mins + 'm';
}

async function refreshStatus() {
    var data = await apiGet('/api/status');
    var badge = document.getElementById('service-status');
    var uptimeEl = document.getElementById('uptime');
    var hostnameEl = document.getElementById('hostname');
    var activeEl = document.getElementById('active-jobs');

    if (data) {
        badge.querySelector('.badge-text').textContent = 'Running';
        badge.className = 'badge badge-running';
        uptimeEl.textContent = formatUptime(data.uptime || 0);
        hostnameEl.textContent = data.hostname || '--';
        var running = (data.processes || []).filter(function(p) { return p.status === 'running'; }).length;
        activeEl.textContent = running;
        if (data.version) {
            var vEl = document.getElementById('version');
            if (vEl) vEl.textContent = 'v' + data.version;
        }
    } else {
        badge.querySelector('.badge-text').textContent = 'Offline';
        badge.className = 'badge badge-stopped';
        uptimeEl.textContent = '--';
        activeEl.textContent = '0';
    }

    document.getElementById('refresh-time').textContent =
        'Last refresh: ' + new Date().toLocaleTimeString();
}

/* ============================================================
   DISK USAGE
   ============================================================ */

async function refreshDisk() {
    var data = await apiGet('/api/disk');
    var usedEl = document.getElementById('disk-used');
    var detailEl = document.getElementById('disk-detail');
    var barEl = document.getElementById('disk-bar');

    if (data) {
        usedEl.textContent = data.used || '--';
        detailEl.textContent = '/ ' + (data.total || '--') + ' (' + (data.available || '--') + ' free)';
        var pct = data.percent || 0;
        barEl.style.width = pct + '%';
        barEl.className = 'progress-fill' + (pct >= 90 ? ' danger' : pct >= 75 ? ' warn' : '');
    }
}

/* ============================================================
   PROCESSES
   ============================================================ */

async function refreshProcesses() {
    var data = await apiGet('/api/processes');
    var tbody = document.getElementById('processes-body');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="empty">No active processes</td></tr>';
        return;
    }

    tbody.innerHTML = data.map(function(proc) {
        var sc = proc.status || 'unknown';
        var canKill = proc.status === 'running';
        return '<tr>' +
            '<td><strong>' + esc(proc.hostname) + '</strong></td>' +
            '<td>' + proc.pid + '</td>' +
            '<td>' + esc(proc.mode) + '</td>' +
            '<td>' + esc(proc.started) + '</td>' +
            '<td><span class="status-cell ' + sc + '"><span class="status-dot"></span>' + esc(proc.status) + '</span></td>' +
            '<td>' + (canKill
                ? '<button class="btn btn-sm btn-danger" onclick="killBackup(\'' + esc(proc.hostname) + '\')">Kill</button>'
                : '--') +
            '</td></tr>';
    }).join('');
}

/* ============================================================
   SERVERS
   ============================================================ */

async function refreshServers() {
    var data = await apiGet('/api/servers');
    var tbody = document.getElementById('servers-body');
    var countEl = document.getElementById('server-count');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty">No servers configured</td></tr>';
        countEl.textContent = '0';
        return;
    }

    countEl.textContent = data.length;

    tbody.innerHTML = data.map(function(srv) {
        var prio = srv.priority || 10;
        var dbInt = srv.db_interval ? srv.db_interval + 'h' : '--';
        return '<tr>' +
            '<td><strong>' + esc(srv.hostname) + '</strong></td>' +
            '<td>' + (esc(srv.options) || '<em style="color:var(--text-muted)">default</em>') + '</td>' +
            '<td>' + prio + '</td>' +
            '<td>' + dbInt + '</td>' +
            '<td>' +
                '<button class="btn btn-sm btn-success" onclick="startBackupFor(\'' + esc(srv.hostname) + '\')">Backup</button> ' +
                '<button class="btn btn-sm" onclick="viewSnapshots(\'' + esc(srv.hostname) + '\')">Snapshots</button> ' +
                '<button class="btn btn-sm btn-danger" onclick="removeServer(\'' + esc(srv.hostname) + '\')">Remove</button>' +
            '</td></tr>';
    }).join('');
}

/* ============================================================
   SSH KEY
   ============================================================ */

async function refreshSSHKey() {
    var data = await apiGet('/api/ssh-key');
    var el = document.getElementById('ssh-key');
    var urlEl = document.getElementById('ssh-key-url');
    var hostEl = document.getElementById('ssh-key-host');

    if (data && data.ssh_public_key) {
        el.textContent = data.ssh_public_key;
        urlEl.textContent = 'curl -s ' + API_BASE + '/api/ssh-key/raw';
        if (data.hostname && hostEl) hostEl.textContent = data.hostname;
    } else {
        el.textContent = 'SSH key not available (service may be offline)';
    }
}

function copySSHKey() {
    var key = document.getElementById('ssh-key').textContent;
    if (key && key.indexOf('SSH key not') !== 0) {
        navigator.clipboard.writeText(key).then(function() {
            toast('SSH key copied to clipboard', 'success');
        });
    }
}

/* ============================================================
   ACTIONS
   ============================================================ */

function toggleAddServer() {
    var form = document.getElementById('add-server-form');
    form.classList.toggle('hidden');
}

async function startBackup() {
    var hostname = document.getElementById('backup-hostname').value.trim();
    var mode = document.getElementById('backup-mode').value;

    if (!hostname) {
        toast('Please enter a hostname', 'error');
        return;
    }

    var result = await apiPost('/api/backup/' + hostname + mode);
    if (result) {
        document.getElementById('backup-hostname').value = '';
        toast('Backup started for ' + hostname, 'success');
        setTimeout(refreshProcesses, 1000);
    } else {
        toast('Failed to start backup for ' + hostname, 'error');
    }
}

async function startBackupFor(hostname) {
    var result = await apiPost('/api/backup/' + hostname);
    if (result) {
        toast('Backup started for ' + hostname, 'success');
    } else {
        toast('Failed to start backup', 'error');
    }
    setTimeout(refreshProcesses, 1000);
}

async function killBackup(hostname) {
    if (!confirm('Kill backup for ' + hostname + '?')) return;
    var result = await apiDelete('/api/backup/' + hostname);
    if (result) {
        toast('Backup killed for ' + hostname, 'info');
    }
    setTimeout(refreshProcesses, 1000);
}

async function addServer() {
    var hostname = document.getElementById('add-server-hostname').value.trim();
    var options = document.getElementById('add-server-options').value;
    var priority = document.getElementById('add-server-priority').value.trim();
    var dbInterval = document.getElementById('add-server-db-interval').value.trim();

    if (!hostname) {
        toast('Please enter a hostname', 'error');
        return;
    }

    if (priority) options += ' --priority ' + priority;
    if (dbInterval) options += ' --db-interval ' + dbInterval + 'h';
    options = options.trim();

    var result = await apiPost('/api/servers', { hostname: hostname, options: options });
    if (result && result.status === 'added') {
        document.getElementById('add-server-hostname').value = '';
        document.getElementById('add-server-options').value = '';
        document.getElementById('add-server-priority').value = '';
        document.getElementById('add-server-db-interval').value = '';
        toast('Server ' + hostname + ' added', 'success');
        refreshServers();
    } else if (result && result.error) {
        toast(result.error, 'error');
    }
}

async function removeServer(hostname) {
    if (!confirm('Remove server ' + hostname + ' from backup list?')) return;
    var result = await apiDelete('/api/servers/' + hostname);
    if (result) {
        toast('Server ' + hostname + ' removed', 'info');
        refreshServers();
    }
}

async function viewSnapshots(hostname) {
    var data = await apiGet('/api/snapshots/' + hostname);
    if (!data || data.length === 0) {
        toast('No snapshots found for ' + hostname, 'info');
        return;
    }

    var rows = data.map(function(s) {
        return '<tr>' +
            '<td>' + esc(s.date) + '</td>' +
            '<td>' + esc(s.size) + '</td>' +
            '<td>' + (s.has_files ? '<span style="color:var(--green)">Yes</span>' : '<span style="color:var(--text-muted)">No</span>') + '</td>' +
            '<td>' + (s.has_sql ? '<span style="color:var(--green)">Yes</span>' : '<span style="color:var(--text-muted)">No</span>') + '</td>' +
            '</tr>';
    }).join('');

    var html = '<table>' +
        '<thead><tr><th>Date</th><th>Size</th><th>Files</th><th>SQL</th></tr></thead>' +
        '<tbody>' + rows + '</tbody>' +
        '</table>';

    openModal('Snapshots: ' + hostname, html);
}

/* ============================================================
   UTILITIES
   ============================================================ */

function esc(str) {
    if (!str) return '';
    var div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

/* ============================================================
   INITIALIZATION
   ============================================================ */

async function refreshAll() {
    await Promise.all([
        refreshStatus(),
        refreshDisk(),
        refreshProcesses(),
        refreshServers(),
        refreshSSHKey()
    ]);
}

refreshAll();
setInterval(refreshAll, REFRESH_INTERVAL);
