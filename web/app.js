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
        const resp = await fetch(API_BASE + endpoint);
        if (!resp.ok) throw new Error('HTTP ' + resp.status + ' ' + resp.statusText);
        const text = await resp.text();
        if (!text) return null;
        _apiErrors = 0;
        return JSON.parse(text);
    } catch (e) {
        _apiErrors++;
        console.error('API GET ' + endpoint + ':', e.message);
        if (_apiErrors === 3) {
            toast('API unreachable: ' + e.message + ' — check if TimeMachine service is running', 'error');
        }
        return null;
    }
}

async function apiPost(endpoint, body) {
    try {
        var opts = { method: 'POST' };
        if (body) {
            opts.headers = { 'Content-Type': 'application/json' };
            opts.body = JSON.stringify(body);
        }
        var resp = await fetch(API_BASE + endpoint, opts);
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        return await resp.json();
    } catch (e) {
        console.error('API POST ' + endpoint + ':', e);
        return null;
    }
}

async function apiDelete(endpoint) {
    try {
        var resp = await fetch(API_BASE + endpoint, { method: 'DELETE' });
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        return await resp.json();
    } catch (e) {
        console.error('API DELETE ' + endpoint + ':', e);
        return null;
    }
}

async function apiPut(endpoint, body) {
    try {
        var resp = await fetch(API_BASE + endpoint, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        return await resp.json();
    } catch (e) {
        console.error('API PUT ' + endpoint + ':', e);
        return null;
    }
}

/* ============================================================
   TOAST NOTIFICATIONS
   ============================================================ */

function toast(message, type) {
    type = type || 'info';
    var container = document.getElementById('toast-container');
    var el = document.createElement('div');
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
   FORMATTING
   ============================================================ */

function formatUptime(seconds) {
    var days = Math.floor(seconds / 86400);
    var hours = Math.floor((seconds % 86400) / 3600);
    var mins = Math.floor((seconds % 3600) / 60);
    if (days > 0) return days + 'd ' + hours + 'h ' + mins + 'm';
    if (hours > 0) return hours + 'h ' + mins + 'm';
    return mins + 'm';
}

function formatMB(mb) {
    if (mb >= 1024) return (mb / 1024).toFixed(1) + ' GB';
    return mb + ' MB';
}

function formatDateTime(str) {
    if (!str || str === 'never') return str || '--';
    // If it's just a date (YYYY-MM-DD), return as-is
    if (/^\d{4}-\d{2}-\d{2}$/.test(str)) return str;
    // If it's a full datetime, format nicely
    try {
        var d = new Date(str.replace(' ', 'T'));
        if (isNaN(d.getTime())) return str;
        return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});
    } catch(e) { return str; }
}

function timeAgo(str) {
    if (!str || str === 'never') return '';
    try {
        var d = new Date(str.replace(' ', 'T'));
        if (isNaN(d.getTime())) return '';
        var secs = Math.floor((Date.now() - d.getTime()) / 1000);
        if (secs < 60) return 'just now';
        if (secs < 3600) return Math.floor(secs / 60) + 'm ago';
        if (secs < 86400) return Math.floor(secs / 3600) + 'h ago';
        return Math.floor(secs / 86400) + 'd ago';
    } catch(e) { return ''; }
}

/* ============================================================
   STATUS
   ============================================================ */

var _serverHostname = '';

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
        _serverHostname = data.hostname || '';
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
   SYSTEM METRICS
   ============================================================ */

async function refreshSystem() {
    var data = await apiGet('/api/system');
    if (!data) return;

    var el = function(id) { return document.getElementById(id); };

    el('sys-load1').textContent = data.load1 || '--';
    el('sys-load5').textContent = data.load5 || '--';

    var memPct = data.mem_percent || 0;
    el('sys-mem-used').textContent = formatMB(data.mem_used || 0);
    el('sys-mem-detail').textContent = ' / ' + formatMB(data.mem_total || 0);
    var memBar = el('mem-bar');
    memBar.style.width = memPct + '%';
    memBar.className = 'progress-fill' + (memPct >= 90 ? ' danger' : memPct >= 75 ? ' warn' : '');

    el('sys-os').textContent = data.os || '--';
    el('sys-kernel').textContent = data.kernel || '--';
    el('sys-cpus').textContent = data.cpu_count || '--';
    el('sys-mem-total').textContent = formatMB(data.mem_total || 0);
    el('sys-uptime').textContent = formatUptime(data.sys_uptime || 0);
    el('sys-load-full').textContent = (data.load1 || '0') + ' / ' + (data.load5 || '0') + ' / ' + (data.load15 || '0');
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
   FAILED BACKUPS
   ============================================================ */

async function refreshFailures() {
    var data = await apiGet('/api/failures');
    var panel = document.getElementById('failures-panel');
    var tbody = document.getElementById('failures-body');

    if (!data || data.length === 0) {
        panel.style.display = 'none';
        return;
    }

    panel.style.display = '';
    tbody.innerHTML = data.map(function(f) {
        var msg = f.message || 'Unknown error';
        if (msg.length > 120) msg = msg.substring(0, 120) + '...';
        var ts = f.timestamp ? '<span class="text-muted" title="' + esc(f.timestamp) + '">' + timeAgo(f.timestamp) + '</span>' : '';
        return '<tr>' +
            '<td><strong>' + esc(f.hostname) + '</strong>' + (ts ? '<br>' + ts : '') + '</td>' +
            '<td class="error-text">' + esc(msg) + '</td>' +
            '<td>' +
                '<button class="btn btn-sm" onclick="viewLogs(\'' + esc(f.hostname) + '\')">Logs</button> ' +
                '<button class="btn btn-sm btn-success" onclick="startBackupFor(\'' + esc(f.hostname) + '\')">Retry</button>' +
            '</td></tr>';
    }).join('');
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
            '<td>' +
                (canKill ? '<button class="btn btn-sm btn-danger" onclick="killBackup(\'' + esc(proc.hostname) + '\')">Kill</button> ' : '') +
                '<button class="btn btn-sm" onclick="viewLogs(\'' + esc(proc.hostname) + '\')">Logs</button>' +
            '</td></tr>';
    }).join('');
}

/* ============================================================
   SERVERS & BACKUP HISTORY
   ============================================================ */

var _historyData = {};

async function refreshHistory() {
    var data = await apiGet('/api/history');
    if (data) {
        _historyData = {};
        data.forEach(function(h) { _historyData[h.hostname] = h; });
    }
}

async function refreshServers() {
    var data = await apiGet('/api/servers');
    var tbody = document.getElementById('servers-body');
    var countEl = document.getElementById('server-count');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="empty">No servers configured</td></tr>';
        countEl.textContent = '0';
        return;
    }

    countEl.textContent = data.length;

    tbody.innerHTML = data.map(function(srv) {
        var h = _historyData[srv.hostname] || {};
        var lastBackup = h.last_backup || 'never';
        var lastTime = h.last_backup_time || '';
        var snapCount = h.snapshots || 0;
        var totalSize = h.total_size || '--';
        var status = h.status || 'unknown';
        var statusClass = status === 'ok' ? 'completed' : status === 'error' ? 'failed' : '';
        var statusLabel = status === 'ok' ? 'OK' : status === 'error' ? 'Error' : '--';

        // Show full datetime if available, otherwise just date
        var backupDisplay = lastTime ? formatDateTime(lastTime) : esc(lastBackup);
        var ago = lastTime ? timeAgo(lastTime) : (lastBackup !== 'never' ? timeAgo(lastBackup) : '');
        var backupCell = backupDisplay + (ago ? ' <span class="text-muted">(' + ago + ')</span>' : '');

        return '<tr>' +
            '<td><strong>' + esc(srv.hostname) + '</strong></td>' +
            '<td>' + backupCell + '</td>' +
            '<td>' + snapCount + '</td>' +
            '<td>' + esc(totalSize) + '</td>' +
            '<td><span class="status-cell ' + statusClass + '"><span class="status-dot"></span>' + statusLabel + '</span></td>' +
            '<td>' +
                '<button class="btn btn-sm btn-success" onclick="startBackupFor(\'' + esc(srv.hostname) + '\')">Backup</button> ' +
                '<button class="btn btn-sm" onclick="editServer(\'' + esc(srv.hostname) + '\')">Edit</button> ' +
                '<button class="btn btn-sm" onclick="viewSnapshots(\'' + esc(srv.hostname) + '\')">Snaps</button> ' +
                '<button class="btn btn-sm" onclick="viewLogs(\'' + esc(srv.hostname) + '\')">Logs</button> ' +
                '<button class="btn btn-sm btn-danger" onclick="removeServer(\'' + esc(srv.hostname) + '\')">&#x2715;</button>' +
            '</td></tr>';
    }).join('');
}

/* ============================================================
   SSH KEY & INSTALLER
   ============================================================ */

async function refreshSSHKey() {
    var data = await apiGet('/api/ssh-key');
    var el = document.getElementById('ssh-key');
    var cmdEl = document.getElementById('installer-cmd');

    if (data && data.ssh_public_key) {
        el.textContent = data.ssh_public_key;
        var host = data.hostname || window.location.hostname;
        cmdEl.textContent = 'curl -sSL https://raw.githubusercontent.com/ronaldjonkers/timemachine-backup-linux/main/get.sh | sudo bash -s -- client --server ' + host;
    } else {
        el.textContent = 'SSH key not available (service may be offline)';
        cmdEl.textContent = 'Service offline — cannot generate installer command';
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

function copyInstaller() {
    var cmd = document.getElementById('installer-cmd').textContent;
    if (cmd && cmd.indexOf('Service offline') !== 0) {
        navigator.clipboard.writeText(cmd).then(function() {
            toast('Installer command copied to clipboard', 'success');
        });
    }
}

/* ============================================================
   LOG VIEWER
   ============================================================ */

async function viewLogs(hostname) {
    var data = await apiGet('/api/logs/' + hostname);
    var content = '';
    if (data && data.lines) {
        content = data.lines;
    } else if (data && data.error) {
        content = data.error;
    } else {
        content = 'No logs available for ' + hostname;
    }

    var html = '<pre class="log-viewer">' + esc(content) + '</pre>';
    openModal('Logs: ' + hostname, html);
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

function startBackupFor(hostname) {
    var html = '<div class="edit-server-form">' +
        '<div class="form-group">' +
            '<label>Backup Mode</label>' +
            '<select id="backup-for-mode">' +
                '<option value="">Full (files + DB)</option>' +
                '<option value="?files-only">Files only</option>' +
                '<option value="?db-only">Database only</option>' +
            '</select>' +
        '</div>' +
        '<div class="form-actions">' +
            '<button class="btn btn-primary btn-success" onclick="runBackupFor(\'' + esc(hostname) + '\')">Start Backup</button>' +
            '<button class="btn" onclick="closeModal()">Cancel</button>' +
        '</div>' +
    '</div>';
    openModal('Backup: ' + hostname, html);
}

async function runBackupFor(hostname) {
    var mode = document.getElementById('backup-for-mode').value;
    closeModal();
    var result = await apiPost('/api/backup/' + hostname + mode);
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

function editServer(hostname) {
    // Find server data from current list
    var data = null;
    var servers = document.querySelectorAll('#servers-body tr');
    // Use the API data we already have
    apiGet('/api/servers').then(function(list) {
        if (!list) return;
        var srv = null;
        for (var i = 0; i < list.length; i++) {
            if (list[i].hostname === hostname) { srv = list[i]; break; }
        }
        if (!srv) { toast('Server not found', 'error'); return; }

        var modeVal = srv.files_only ? 'files-only' : (srv.db_only ? 'db-only' : 'full');

        var html = '<div class="edit-server-form">' +
            '<div class="form-group">' +
                '<label>Backup Mode</label>' +
                '<select id="edit-mode">' +
                    '<option value="full"' + (modeVal === 'full' ? ' selected' : '') + '>Full (files + DB)</option>' +
                    '<option value="files-only"' + (modeVal === 'files-only' ? ' selected' : '') + '>Files only</option>' +
                    '<option value="db-only"' + (modeVal === 'db-only' ? ' selected' : '') + '>Database only</option>' +
                '</select>' +
            '</div>' +
            '<div class="form-group">' +
                '<label>Priority <span class="text-muted">(1 = highest, default 10)</span></label>' +
                '<input type="number" id="edit-priority" value="' + (srv.priority || 10) + '" min="1" max="99">' +
            '</div>' +
            '<div class="form-group">' +
                '<label>DB Backup Interval <span class="text-muted">(hours, 0 = only with daily backup)</span></label>' +
                '<input type="number" id="edit-db-interval" value="' + (srv.db_interval || 0) + '" min="0" max="24">' +
            '</div>' +
            '<div class="form-group">' +
                '<label><input type="checkbox" id="edit-no-rotate"' + (srv.no_rotate ? ' checked' : '') + '> Skip backup rotation</label>' +
            '</div>' +
            '<div class="form-actions">' +
                '<button class="btn btn-primary" onclick="saveServerSettings(\'' + esc(hostname) + '\')">Save</button>' +
                '<button class="btn" onclick="closeModal()">Cancel</button>' +
            '</div>' +
        '</div>';

        openModal('Settings: ' + hostname, html);
    });
}

async function saveServerSettings(hostname) {
    var mode = document.getElementById('edit-mode').value;
    var priority = parseInt(document.getElementById('edit-priority').value) || 10;
    var dbInterval = parseInt(document.getElementById('edit-db-interval').value) || 0;
    var noRotate = document.getElementById('edit-no-rotate').checked;

    var result = await apiPut('/api/servers/' + hostname, {
        mode: mode,
        priority: priority,
        db_interval: dbInterval,
        no_rotate: noRotate
    });

    if (result && result.status === 'updated') {
        toast('Settings saved for ' + hostname, 'success');
        closeModal();
        await refreshHistory();
        refreshServers();
    } else {
        toast('Failed to save settings', 'error');
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
        refreshSystem(),
        refreshDisk(),
        refreshFailures(),
        refreshProcesses(),
        refreshHistory().then(refreshServers),
        refreshSSHKey()
    ]);
}

refreshAll();
setInterval(refreshAll, REFRESH_INTERVAL);
