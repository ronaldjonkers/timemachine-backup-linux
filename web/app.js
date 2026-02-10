/* ============================================================
   TimeMachine Backup - Dashboard JavaScript
   ============================================================ */

const API_BASE = window.location.origin;
const REFRESH_INTERVAL = 10000;

/* ============================================================
   PAGE NAVIGATION
   ============================================================ */

function showPage(page) {
    document.querySelectorAll('.page').forEach(function(p) { p.classList.remove('active'); });
    document.querySelectorAll('.nav-tab').forEach(function(t) { t.classList.remove('active'); });
    var pageEl = document.getElementById('page-' + page);
    if (pageEl) pageEl.classList.add('active');
    var tabEl = document.querySelector('.nav-tab[data-page="' + page + '"]');
    if (tabEl) tabEl.classList.add('active');
}

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
    _stopLogStream();
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
    var hostnameEl = document.getElementById('hostname');
    var activeEl = document.getElementById('active-jobs');

    if (data) {
        badge.querySelector('.badge-text').textContent = 'Running';
        badge.className = 'badge badge-running';
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
    var mountEl = document.getElementById('disk-mount');

    if (data) {
        usedEl.textContent = data.used || '--';
        detailEl.textContent = '/ ' + (data.total || '--') + ' (' + (data.available || '--') + ' free)';
        var pct = data.percent || 0;
        barEl.style.width = pct + '%';
        barEl.className = 'progress-fill' + (pct >= 90 ? ' danger' : pct >= 75 ? ' warn' : '');
        if (mountEl && data.mount) mountEl.textContent = '(' + data.mount + ')';
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

function formatDuration(startedStr) {
    if (!startedStr) return '--';
    var started = new Date(startedStr.replace(' ', 'T'));
    if (isNaN(started.getTime())) return '--';
    var secs = Math.floor((Date.now() - started.getTime()) / 1000);
    if (secs < 0) secs = 0;
    var h = Math.floor(secs / 3600);
    var m = Math.floor((secs % 3600) / 60);
    var s = secs % 60;
    if (h > 0) return h + 'h ' + m + 'm';
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
}

var _prevRunningHosts = {};

async function refreshProcesses() {
    var data = await apiGet('/api/processes');
    var tbody = document.getElementById('processes-body');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="7" class="empty">No active processes</td></tr>';
        // Check if any previously running hosts just finished
        for (var h in _prevRunningHosts) {
            if (_prevRunningHosts[h]) toast('Backup completed: ' + h, 'success');
        }
        _prevRunningHosts = {};
        return;
    }

    // Detect transitions from running -> completed/failed
    var currentRunning = {};
    data.forEach(function(proc) {
        if (proc.status === 'running') currentRunning[proc.hostname] = true;
    });
    for (var h in _prevRunningHosts) {
        if (_prevRunningHosts[h] && !currentRunning[h]) {
            var finished = data.find(function(p) { return p.hostname === h; });
            if (finished && finished.status === 'failed') {
                toast('Backup failed: ' + h, 'error');
            } else {
                toast('Backup completed: ' + h, 'success');
            }
        }
    }
    _prevRunningHosts = currentRunning;

    tbody.innerHTML = data.map(function(proc) {
        var sc = proc.status || 'unknown';
        var canKill = proc.status === 'running';
        var duration = proc.status === 'running' ? formatDuration(proc.started) : '--';
        return '<tr>' +
            '<td><strong>' + esc(proc.hostname) + '</strong></td>' +
            '<td>' + proc.pid + '</td>' +
            '<td>' + esc(proc.mode) + '</td>' +
            '<td>' + esc(proc.started) + '</td>' +
            '<td>' + duration + '</td>' +
            '<td><span class="status-cell ' + sc + '"><span class="status-dot"></span>' + esc(proc.status) + '</span></td>' +
            '<td>' +
                (canKill ? '<button class="btn btn-sm btn-danger" onclick="killBackup(\'' + esc(proc.hostname) + '\')">Kill</button> ' : '') +
                '<button class="btn btn-sm" onclick="viewLogs(\'' + esc(proc.hostname) + '\')">Logs</button> ' +
                '<button class="btn btn-sm" onclick="viewRsyncLog(\'' + esc(proc.hostname) + '\')">Rsync</button>' +
            '</td></tr>';
    }).join('');
}

/* ============================================================
   RESTORE TASKS
   ============================================================ */

async function refreshRestores() {
    var data = await apiGet('/api/restores');
    var tbody = document.getElementById('restores-body');
    var clearBtn = document.getElementById('restores-clear-btn');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty">No restore tasks</td></tr>';
        if (clearBtn) clearBtn.style.display = 'none';
        return;
    }
    var hasFinished = data.some(function(r) { return r.status !== 'running'; });
    if (clearBtn) clearBtn.style.display = hasFinished ? '' : 'none';

    tbody.innerHTML = data.map(function(r) {
        var sc = r.status || 'unknown';
        var statusClass = sc === 'completed' ? 'success' : (sc === 'failed' ? 'failed' : sc);
        var canDelete = r.status !== 'running';
        return '<tr>' +
            '<td><strong>' + esc(r.hostname) + '</strong></td>' +
            '<td>' + esc(r.description) + '</td>' +
            '<td>' + esc(r.started) + '</td>' +
            '<td><span class="status-cell ' + statusClass + '"><span class="status-dot"></span>' + esc(r.status) + '</span></td>' +
            '<td>' +
                '<button class="btn btn-sm" onclick="viewRestoreLog(\'' + esc(r.logfile) + '\',\'' + esc(r.hostname) + '\')">Logs</button> ' +
                (canDelete ? '<button class="btn btn-sm btn-danger" onclick="deleteRestore(\'' + esc(r.id) + '\')">Delete</button>' : '') +
            '</td></tr>';
    }).join('');
}

async function deleteRestore(id) {
    var result = await apiDelete('/api/restore/' + id);
    if (result && result.status === 'deleted') {
        toast('Restore task deleted', 'info');
        refreshRestores();
    } else {
        toast('Failed to delete restore task', 'error');
    }
}

async function clearFinishedRestores() {
    var result = await apiDelete('/api/restores');
    if (result && result.status === 'cleared') {
        toast('Cleared ' + result.count + ' finished restore task(s)', 'info');
        refreshRestores();
    } else {
        toast('Failed to clear restore tasks', 'error');
    }
}

async function viewRestoreLog(logfile, hostname) {
    _logHost = '__restore__' + logfile;
    _stopLogStream();

    var data = await apiGet('/api/restore-log/' + logfile);
    if (!data) {
        openModal('Restore Log', '<p>Log not available</p>');
        return;
    }

    var content = data.lines || data.error || 'No log content';
    var isRunning = data.running || false;

    var statusBadge = isRunning
        ? '<span class="badge badge-running" id="log-status"><span class="pulse"></span> Live</span>'
        : '<span class="badge badge-idle" id="log-status">Completed</span>';

    var html = '<div class="log-header">' +
            statusBadge +
            '<span class="text-muted" id="log-filename">' + esc(logfile) + '</span>' +
        '</div>' +
        '<pre class="log-viewer" id="log-content">' + esc(content) + '</pre>';

    openModal('Restore Log: ' + hostname, html);

    var logEl = document.getElementById('log-content');
    if (logEl) logEl.scrollTop = logEl.scrollHeight;

    if (isRunning) {
        _startRestoreLogStream(logfile);
    }
}

function _startRestoreLogStream(logfile) {
    _stopLogStream();
    _logInterval = setInterval(async function() {
        var data = await apiGet('/api/restore-log/' + logfile);
        if (!data) return;

        var logEl = document.getElementById('log-content');
        var statusEl = document.getElementById('log-status');
        if (!logEl) { _stopLogStream(); return; }

        var wasAtBottom = (logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight) < 50;
        logEl.textContent = data.lines || '';
        if (wasAtBottom) logEl.scrollTop = logEl.scrollHeight;

        if (statusEl) {
            if (data.running) {
                statusEl.className = 'badge badge-running';
                statusEl.innerHTML = '<span class="pulse"></span> Live';
            } else {
                statusEl.className = 'badge badge-idle';
                statusEl.textContent = 'Completed';
                _stopLogStream();
                refreshRestores();
            }
        }
    }, 2000);
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
                '<button class="btn btn-sm btn-primary" onclick="openServerDetail(\'' + esc(srv.hostname) + '\')">Details</button> ' +
                '<button class="btn btn-sm btn-success" onclick="startBackupFor(\'' + esc(srv.hostname) + '\')">Backup</button> ' +
                '<button class="btn btn-sm" onclick="editServer(\'' + esc(srv.hostname) + '\')">Edit</button> ' +
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
   SETTINGS
   ============================================================ */

async function refreshSettings() {
    var data = await apiGet('/api/settings');
    if (!data) return;

    var el = function(id) { return document.getElementById(id); };
    if (el('setting-schedule-hour')) el('setting-schedule-hour').value = data.schedule_hour;
    if (el('setting-schedule-minute')) el('setting-schedule-minute').value = data.schedule_minute || 0;
    if (el('setting-retention-days')) el('setting-retention-days').value = data.retention_days;
    if (el('setting-parallel-jobs')) el('setting-parallel-jobs').value = data.parallel_jobs || 5;
    if (el('setting-alert-enabled')) el('setting-alert-enabled').checked = (data.alert_enabled === 'true');
    if (el('setting-alert-email')) el('setting-alert-email').value = data.alert_email || '';
    if (el('setting-notify-backup-ok')) el('setting-notify-backup-ok').checked = (data.notify_backup_ok !== 'false');
    if (el('setting-notify-backup-fail')) el('setting-notify-backup-fail').checked = (data.notify_backup_fail !== 'false');
    if (el('setting-notify-restore-ok')) el('setting-notify-restore-ok').checked = (data.notify_restore_ok !== 'false');
    if (el('setting-notify-restore-fail')) el('setting-notify-restore-fail').checked = (data.notify_restore_fail !== 'false');
    if (el('setting-email-backup-ok')) el('setting-email-backup-ok').value = data.alert_email_backup_ok || '';
    if (el('setting-email-backup-fail')) el('setting-email-backup-fail').value = data.alert_email_backup_fail || '';
    if (el('setting-email-restore-ok')) el('setting-email-restore-ok').value = data.alert_email_restore_ok || '';
    if (el('setting-email-restore-fail')) el('setting-email-restore-fail').value = data.alert_email_restore_fail || '';
    if (el('setting-smtp-host')) el('setting-smtp-host').value = data.smtp_host || '';
    if (el('setting-smtp-port')) el('setting-smtp-port').value = data.smtp_port || 587;
    if (el('setting-smtp-user')) el('setting-smtp-user').value = data.smtp_user || '';
    if (el('setting-smtp-pass')) el('setting-smtp-pass').value = data.smtp_pass || '';
    if (el('setting-smtp-from')) el('setting-smtp-from').value = data.smtp_from || '';
    if (el('setting-smtp-tls')) el('setting-smtp-tls').checked = (data.smtp_tls !== 'false');
}

async function saveSettings() {
    var hour = parseInt(document.getElementById('setting-schedule-hour').value, 10);
    var retention = parseInt(document.getElementById('setting-retention-days').value, 10);
    var statusEl = document.getElementById('settings-status');

    if (isNaN(hour) || hour < 0 || hour > 23) {
        toast('Schedule hour must be 0-23', 'error');
        return;
    }
    if (isNaN(retention) || retention < 1 || retention > 365) {
        toast('Retention days must be 1-365', 'error');
        return;
    }

    var parallelJobs = parseInt(document.getElementById('setting-parallel-jobs').value, 10);
    if (isNaN(parallelJobs) || parallelJobs < 1 || parallelJobs > 50) {
        toast('Parallel jobs must be 1-50', 'error');
        return;
    }

    var minute = parseInt(document.getElementById('setting-schedule-minute').value, 10) || 0;

    var payload = {
        schedule_hour: hour,
        schedule_minute: minute,
        retention_days: retention,
        parallel_jobs: parallelJobs,
        alert_enabled: document.getElementById('setting-alert-enabled').checked ? 'true' : 'false',
        alert_email: document.getElementById('setting-alert-email').value.trim(),
        notify_backup_ok: document.getElementById('setting-notify-backup-ok').checked ? 'true' : 'false',
        notify_backup_fail: document.getElementById('setting-notify-backup-fail').checked ? 'true' : 'false',
        notify_restore_ok: document.getElementById('setting-notify-restore-ok').checked ? 'true' : 'false',
        notify_restore_fail: document.getElementById('setting-notify-restore-fail').checked ? 'true' : 'false',
        alert_email_backup_ok: document.getElementById('setting-email-backup-ok').value.trim(),
        alert_email_backup_fail: document.getElementById('setting-email-backup-fail').value.trim(),
        alert_email_restore_ok: document.getElementById('setting-email-restore-ok').value.trim(),
        alert_email_restore_fail: document.getElementById('setting-email-restore-fail').value.trim(),
        smtp_host: document.getElementById('setting-smtp-host').value.trim(),
        smtp_port: parseInt(document.getElementById('setting-smtp-port').value, 10) || 587,
        smtp_user: document.getElementById('setting-smtp-user').value.trim(),
        smtp_pass: document.getElementById('setting-smtp-pass').value,
        smtp_from: document.getElementById('setting-smtp-from').value.trim(),
        smtp_tls: document.getElementById('setting-smtp-tls').checked ? 'true' : 'false'
    };

    statusEl.textContent = 'Saving...';
    var result = await apiPut('/api/settings', payload);
    if (result && result.status === 'saved') {
        statusEl.textContent = 'Saved';
        toast('Settings saved', 'success');
        setTimeout(function() { statusEl.textContent = ''; }, 3000);
    } else {
        statusEl.textContent = 'Failed';
        toast('Failed to save settings', 'error');
    }
}

async function sendTestEmail() {
    var statusEl = document.getElementById('test-email-status');
    statusEl.textContent = 'Sending...';
    var payload = {
        smtp_host: document.getElementById('setting-smtp-host').value.trim(),
        smtp_port: parseInt(document.getElementById('setting-smtp-port').value, 10) || 587,
        smtp_user: document.getElementById('setting-smtp-user').value.trim(),
        smtp_pass: document.getElementById('setting-smtp-pass').value,
        smtp_from: document.getElementById('setting-smtp-from').value.trim(),
        smtp_tls: document.getElementById('setting-smtp-tls').checked ? 'true' : 'false',
        recipient: document.getElementById('setting-alert-email').value.trim()
    };
    var result = await apiPost('/api/test-email', payload);
    if (result && result.status === 'sent') {
        statusEl.textContent = 'Sent to ' + result.recipient;
        toast('Test email sent to ' + result.recipient, 'success');
    } else {
        statusEl.textContent = (result && result.error) || 'Failed';
        toast((result && result.error) || 'Failed to send test email', 'error');
    }
    setTimeout(function() { statusEl.textContent = ''; }, 5000);
}

/* ============================================================
   EXCLUDE PATTERNS
   ============================================================ */

async function refreshExcludes() {
    var data = await apiGet('/api/excludes');
    if (data && data.content !== undefined) {
        document.getElementById('exclude-global').value = data.content;
    }
    // Populate server dropdown
    var servers = await apiGet('/api/servers');
    var sel = document.getElementById('exclude-server-select');
    if (servers && sel) {
        var current = sel.value;
        sel.innerHTML = '<option value="">-- select server --</option>';
        servers.forEach(function(s) {
            var opt = document.createElement('option');
            opt.value = s.hostname;
            opt.textContent = s.hostname;
            sel.appendChild(opt);
        });
        if (current) sel.value = current;
    }
}

async function loadServerExcludes() {
    var sel = document.getElementById('exclude-server-select');
    var ta = document.getElementById('exclude-server');
    var btn = document.getElementById('btn-save-server-excludes');
    var hostname = sel.value;
    if (!hostname) {
        ta.value = '';
        ta.disabled = true;
        btn.disabled = true;
        return;
    }
    ta.disabled = false;
    btn.disabled = false;
    var data = await apiGet('/api/excludes/' + encodeURIComponent(hostname));
    if (data && data.content !== undefined) {
        ta.value = data.content;
    } else {
        ta.value = '';
    }
}

async function saveExcludes() {
    var content = document.getElementById('exclude-global').value;
    var statusEl = document.getElementById('exclude-global-status');
    statusEl.textContent = 'Saving...';
    var result = await apiPut('/api/excludes', { content: content });
    if (result && result.status === 'saved') {
        statusEl.textContent = 'Saved';
        toast('Global excludes saved', 'success');
        setTimeout(function() { statusEl.textContent = ''; }, 3000);
    } else {
        statusEl.textContent = 'Failed';
        toast('Failed to save global excludes', 'error');
    }
}

async function saveServerExcludes() {
    var hostname = document.getElementById('exclude-server-select').value;
    if (!hostname) return;
    var content = document.getElementById('exclude-server').value;
    var statusEl = document.getElementById('exclude-server-status');
    statusEl.textContent = 'Saving...';
    var result = await apiPut('/api/excludes/' + encodeURIComponent(hostname), { content: content });
    if (result && result.status === 'saved') {
        statusEl.textContent = 'Saved';
        toast('Excludes saved for ' + hostname, 'success');
        setTimeout(function() { statusEl.textContent = ''; }, 3000);
    } else {
        statusEl.textContent = 'Failed';
        toast('Failed to save excludes for ' + hostname, 'error');
    }
}

/* ============================================================
   ARCHIVE
   ============================================================ */

async function refreshArchived() {
    var data = await apiGet('/api/archived');
    var tbody = document.getElementById('archived-body');
    var taskPanel = document.getElementById('delete-tasks-panel');
    var taskBody = document.getElementById('delete-tasks-body');

    if (!data) return;

    var servers = data.servers || [];
    var tasks = data.delete_tasks || [];

    if (servers.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty">No archived servers</td></tr>';
    } else {
        tbody.innerHTML = servers.map(function(srv) {
            return '<tr>' +
                '<td><strong>' + esc(srv.hostname) + '</strong></td>' +
                '<td>' + esc(srv.last_backup || '--') + '</td>' +
                '<td>' + (srv.snapshots || 0) + '</td>' +
                '<td>' + esc(srv.total_size || '--') + '</td>' +
                '<td>' +
                    '<button class="btn btn-sm" onclick="openServerDetail(\'' + esc(srv.hostname) + '\')">Browse</button> ' +
                    '<button class="btn btn-sm btn-success" onclick="unarchiveServer(\'' + esc(srv.hostname) + '\')">Re-activate</button> ' +
                    '<button class="btn btn-sm btn-danger" onclick="deleteArchivedServer(\'' + esc(srv.hostname) + '\')">Delete</button>' +
                '</td></tr>';
        }).join('');
    }

    // Show background deletion tasks
    if (tasks.length > 0) {
        taskPanel.style.display = '';
        taskBody.innerHTML = tasks.map(function(t) {
            var sc = t.status === 'running' ? 'running' : (t.status === 'completed' ? 'success' : 'failed');
            var startedStr = t.started ? new Date(t.started * 1000).toLocaleString() : '--';
            return '<tr>' +
                '<td>' + esc(t.hostname) + '</td>' +
                '<td><span class="status-cell ' + sc + '"><span class="status-dot"></span>' + esc(t.status) +
                    (t.status === 'running' ? ' (this may take a while)' : '') + '</span></td>' +
                '<td>' + startedStr + '</td>' +
            '</tr>';
        }).join('');
    } else {
        taskPanel.style.display = 'none';
    }
}

async function unarchiveServer(hostname) {
    if (!confirm('Re-activate ' + hostname + '? It will be added back to the daily backup schedule.')) return;
    var result = await apiPost('/api/archived/' + hostname + '/unarchive');
    if (result && result.status === 'unarchived') {
        toast(hostname + ' re-activated — daily backups will resume', 'success');
        refreshServers();
        refreshArchived();
    } else {
        toast('Failed to re-activate ' + hostname, 'error');
    }
}

async function deleteArchivedServer(hostname) {
    if (!confirm('PERMANENTLY delete ' + hostname + ' and ALL backup data? This cannot be undone!')) return;
    var result = await apiDelete('/api/archived/' + hostname);
    if (result && result.status === 'deleting') {
        toast(hostname + ' — data deletion running in background', 'info');
        refreshArchived();
    } else {
        toast('Failed to delete ' + hostname, 'error');
    }
}

/* ============================================================
   LOG VIEWER (live streaming)
   ============================================================ */

var _logInterval = null;
var _logHost = '';

async function viewLogs(hostname) {
    _logHost = hostname;
    _stopLogStream();

    var data = await apiGet('/api/logs/' + hostname);
    if (!data) {
        openModal('Logs: ' + hostname, '<p>No logs available for ' + esc(hostname) + '</p>');
        return;
    }

    var content = data.lines || data.error || 'No logs available';
    var isRunning = data.running || false;

    var statusBadge = isRunning
        ? '<span class="badge badge-running" id="log-status"><span class="pulse"></span> Live</span>'
        : '<span class="badge badge-idle" id="log-status">Completed</span>';

    var html = '<div class="log-header">' +
            statusBadge +
            '<span class="text-muted" id="log-filename">' + esc(data.logfile || '') + '</span>' +
        '</div>' +
        '<pre class="log-viewer" id="log-content">' + esc(content) + '</pre>';

    openModal('Logs: ' + hostname, html);

    // Scroll to bottom
    var logEl = document.getElementById('log-content');
    if (logEl) logEl.scrollTop = logEl.scrollHeight;

    // Start live polling if running
    if (isRunning) {
        _startLogStream(hostname);
    }
}

function _startLogStream(hostname) {
    _stopLogStream();
    _logInterval = setInterval(async function() {
        if (_logHost !== hostname) { _stopLogStream(); return; }

        var data = await apiGet('/api/logs/' + hostname);
        if (!data) return;

        var logEl = document.getElementById('log-content');
        var statusEl = document.getElementById('log-status');
        if (!logEl) { _stopLogStream(); return; }

        // Check if user is scrolled to bottom (within 50px)
        var wasAtBottom = (logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight) < 50;

        logEl.textContent = data.lines || '';

        // Auto-scroll if user was at bottom
        if (wasAtBottom) logEl.scrollTop = logEl.scrollHeight;

        // Update status badge
        if (statusEl) {
            if (data.running) {
                statusEl.className = 'badge badge-running';
                statusEl.innerHTML = '<span class="pulse"></span> Live';
            } else {
                statusEl.className = 'badge badge-idle';
                statusEl.textContent = 'Completed';
                _stopLogStream();
                // Refresh processes table since backup finished
                refreshProcesses();
            }
        }
    }, 2000);
}

function _stopLogStream() {
    if (_logInterval) {
        clearInterval(_logInterval);
        _logInterval = null;
    }
}

async function viewRsyncLog(hostname) {
    _logHost = '__rsync__' + hostname;
    _stopLogStream();

    var data = await apiGet('/api/rsync-log/' + hostname);
    if (!data || data.error) {
        openModal('Rsync Log: ' + hostname, '<p>No rsync log available for ' + esc(hostname) + '</p>');
        return;
    }

    var content = data.lines || 'No rsync log content';
    var isRunning = data.running || false;

    var statusBadge = isRunning
        ? '<span class="badge badge-running" id="log-status"><span class="pulse"></span> Live</span>'
        : '<span class="badge badge-idle" id="log-status">Completed</span>';

    var html = '<div class="log-header">' +
            statusBadge +
            '<span class="text-muted" id="log-filename">' + esc(data.logfile || '') + '</span>' +
        '</div>' +
        '<pre class="log-viewer" id="log-content">' + esc(content) + '</pre>';

    openModal('Rsync Log: ' + hostname, html);

    var logEl = document.getElementById('log-content');
    if (logEl) logEl.scrollTop = logEl.scrollHeight;

    if (isRunning) {
        _startRsyncLogStream(hostname);
    }
}

function _startRsyncLogStream(hostname) {
    _stopLogStream();
    _logInterval = setInterval(async function() {
        if (_logHost !== '__rsync__' + hostname) { _stopLogStream(); return; }

        var data = await apiGet('/api/rsync-log/' + hostname);
        if (!data) return;

        var logEl = document.getElementById('log-content');
        var statusEl = document.getElementById('log-status');
        if (!logEl) { _stopLogStream(); return; }

        var wasAtBottom = (logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight) < 50;
        logEl.textContent = data.lines || '';
        if (wasAtBottom) logEl.scrollTop = logEl.scrollHeight;

        if (statusEl) {
            if (data.running) {
                statusEl.className = 'badge badge-running';
                statusEl.innerHTML = '<span class="pulse"></span> Live';
            } else {
                statusEl.className = 'badge badge-idle';
                statusEl.textContent = 'Completed';
                _stopLogStream();
            }
        }
    }, 2000);
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

function removeServer(hostname) {
    var html = '<p>What would you like to do with <strong>' + esc(hostname) + '</strong>?</p>' +
        '<div style="display:flex;flex-direction:column;gap:0.75rem;margin-top:1rem">' +
            '<button class="btn btn-primary" onclick="archiveServer(\'' + esc(hostname) + '\')" style="text-align:left;padding:0.75rem 1rem">' +
                '<strong>&#x1F4E6; Archive</strong><br>' +
                '<small class="text-muted">Stop daily backups but keep all existing snapshots. You can browse and restore from the Archive tab.</small>' +
            '</button>' +
            '<button class="btn btn-danger" onclick="fullDeleteServer(\'' + esc(hostname) + '\')" style="text-align:left;padding:0.75rem 1rem">' +
                '<strong>&#x1F5D1; Delete permanently</strong><br>' +
                '<small>Remove server AND delete all backup data. This runs in the background and cannot be undone.</small>' +
            '</button>' +
        '</div>';
    openModal('Remove Server', html);
}

async function archiveServer(hostname) {
    closeModal();
    var result = await apiDelete('/api/servers/' + hostname + '?action=archive');
    if (result && result.status === 'archived') {
        toast(hostname + ' archived — snapshots preserved', 'success');
        refreshServers();
        refreshArchived();
    } else {
        toast('Failed to archive ' + hostname, 'error');
    }
}

async function fullDeleteServer(hostname) {
    closeModal();
    if (!confirm('PERMANENTLY delete ' + hostname + ' and ALL backup data? This cannot be undone!')) return;
    var result = await apiDelete('/api/servers/' + hostname + '?action=delete');
    if (result && result.status === 'deleting') {
        toast(hostname + ' removed. Data deletion running in background.', 'info');
        refreshServers();
        refreshArchived();
    } else {
        toast('Failed to delete ' + hostname, 'error');
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
            '<div class="form-group">' +
                '<label>Notification email <span class="text-muted">(extra recipient for this server)</span></label>' +
                '<input type="email" id="edit-notify-email" value="' + esc(srv.notify_email || '') + '" placeholder="admin@example.com">' +
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
    var notifyEmail = document.getElementById('edit-notify-email').value.trim();

    var result = await apiPut('/api/servers/' + hostname, {
        mode: mode,
        priority: priority,
        db_interval: dbInterval,
        no_rotate: noRotate,
        notify_email: notifyEmail
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

var _snapPage = 0;
var _snapPerPage = 15;
var _snapData = [];
var _snapHost = '';

async function openServerDetail(hostname) {
    // Switch to servers page if not already there (e.g. called from Archive)
    showPage('servers');

    var panel = document.getElementById('server-detail-panel');
    var title = document.getElementById('server-detail-title');
    var body = document.getElementById('server-detail-body');

    title.innerHTML = '&#x1F5A5; ' + esc(hostname);
    body.innerHTML = '<div style="padding:1.25rem" class="text-muted">Loading snapshots...</div>';
    panel.style.display = '';
    panel.scrollIntoView({ behavior: 'smooth', block: 'start' });

    var data = await apiGet('/api/snapshots/' + hostname);
    if (!data || data.length === 0) {
        body.innerHTML = '<div style="padding:1.25rem" class="text-muted">No snapshots found for this server</div>';
        return;
    }

    _snapData = data.reverse();
    _snapHost = hostname;
    _snapPage = 0;
    _renderServerDetail();
}

function closeServerDetail() {
    document.getElementById('server-detail-panel').style.display = 'none';
}

function _renderServerDetail() {
    var body = document.getElementById('server-detail-body');
    var hostname = _snapHost;
    var totalPages = Math.ceil(_snapData.length / _snapPerPage);
    var start = _snapPage * _snapPerPage;
    var pageData = _snapData.slice(start, start + _snapPerPage);

    var rows = pageData.map(function(s) {
        return '<tr>' +
            '<td>' + esc(s.date) + '</td>' +
            '<td>' + esc(s.size) + '</td>' +
            '<td>' + (s.has_files ? '<span style="color:var(--green)">Yes</span>' : '<span style="color:var(--text-muted)">No</span>') + '</td>' +
            '<td>' + (s.has_db ? '<span style="color:var(--green)">Yes</span>' : '<span style="color:var(--text-muted)">No</span>') + '</td>' +
            '<td>' +
                '<button class="btn btn-sm" onclick="browseSnapshot(\'' + esc(hostname) + '\',\'' + esc(s.date) + '\')">Browse</button> ' +
                '<button class="btn btn-sm btn-success" onclick="downloadChoice(\'' + esc(hostname) + '\',\'' + esc(s.date) + '\',\'files\')">Download</button> ' +
                '<button class="btn btn-sm" onclick="restoreItem(\'' + esc(hostname) + '\',\'' + esc(s.date) + '\',\'\')">Restore</button>' +
            '</td>' +
            '</tr>';
    }).join('');

    var pagination = '';
    if (totalPages > 1) {
        pagination = '<div class="form-actions" style="margin-top:0.75rem;justify-content:center;border-top:none">';
        if (_snapPage > 0) {
            pagination += '<button class="btn btn-sm" onclick="_snapPage=' + (_snapPage - 1) + ';_renderServerDetail()">Previous</button> ';
        }
        pagination += '<span class="text-muted" style="padding:0.3rem 0.5rem;font-size:0.82rem">Page ' + (_snapPage + 1) + ' of ' + totalPages + ' (' + _snapData.length + ' snapshots)</span>';
        if (_snapPage < totalPages - 1) {
            pagination += ' <button class="btn btn-sm" onclick="_snapPage=' + (_snapPage + 1) + ';_renderServerDetail()">Next</button>';
        }
        pagination += '</div>';
    }

    body.innerHTML = '<table>' +
        '<thead><tr><th>Date</th><th>Size</th><th>Files</th><th>Database</th><th>Actions</th></tr></thead>' +
        '<tbody>' + rows + '</tbody>' +
        '</table>' + pagination;
}

async function viewSnapshots(hostname, page) {
    if (hostname !== _snapHost || typeof page === 'undefined') {
        var data = await apiGet('/api/snapshots/' + hostname);
        if (!data || data.length === 0) {
            toast('No snapshots found for ' + hostname, 'info');
            return;
        }
        // Sort newest first
        _snapData = data.reverse();
        _snapHost = hostname;
        _snapPage = 0;
    }
    if (typeof page !== 'undefined') _snapPage = page;

    var totalPages = Math.ceil(_snapData.length / _snapPerPage);
    var start = _snapPage * _snapPerPage;
    var pageData = _snapData.slice(start, start + _snapPerPage);

    var rows = pageData.map(function(s) {
        return '<tr>' +
            '<td>' + esc(s.date) + '</td>' +
            '<td>' + esc(s.size) + '</td>' +
            '<td>' + (s.has_files ? '<span style="color:var(--green)">Yes</span>' : '<span style="color:var(--text-muted)">No</span>') + '</td>' +
            '<td>' + (s.has_db ? '<span style="color:var(--green)">Yes</span>' : '<span style="color:var(--text-muted)">No</span>') + '</td>' +
            '<td>' +
                '<button class="btn btn-sm" onclick="browseSnapshot(\'' + esc(hostname) + '\',\'' + esc(s.date) + '\')">Browse</button> ' +
                '<button class="btn btn-sm btn-success" onclick="downloadChoice(\'' + esc(hostname) + '\',\'' + esc(s.date) + '\',\'files\')">Download</button>' +
            '</td>' +
            '</tr>';
    }).join('');

    var pagination = '';
    if (totalPages > 1) {
        pagination = '<div class="form-actions" style="margin-top:0.75rem;justify-content:center">';
        if (_snapPage > 0) {
            pagination += '<button class="btn btn-sm" onclick="viewSnapshots(\'' + esc(hostname) + '\',' + (_snapPage - 1) + ')">Previous</button> ';
        }
        pagination += '<span class="text-muted" style="padding:0.3rem 0.5rem;font-size:0.82rem">Page ' + (_snapPage + 1) + ' of ' + totalPages + ' (' + _snapData.length + ' snapshots)</span>';
        if (_snapPage < totalPages - 1) {
            pagination += ' <button class="btn btn-sm" onclick="viewSnapshots(\'' + esc(hostname) + '\',' + (_snapPage + 1) + ')">Next</button>';
        }
        pagination += '</div>';
    }

    var html = '<table>' +
        '<thead><tr><th>Date</th><th>Size</th><th>Files</th><th>Database</th><th>Actions</th></tr></thead>' +
        '<tbody>' + rows + '</tbody>' +
        '</table>' + pagination;

    openModal('Snapshots: ' + hostname + ' (last 3 months)', html);
}

/* ============================================================
   BROWSE & RESTORE
   ============================================================ */

var _browseHost = '';
var _browseSnap = '';
var _browsePath = '';

async function browseSnapshot(hostname, snapshot, subPath) {
    _browseHost = hostname;
    _browseSnap = snapshot;
    _browsePath = subPath || '';

    // If no subPath, show snapshot root with files/ and sql/ sections
    if (!subPath) {
        var filesData = await apiGet('/api/browse/' + hostname + '/' + snapshot);
        var sqlData = await apiGet('/api/browse/' + hostname + '/' + snapshot + '/sql');

        var html = '<div class="breadcrumb"><strong>' + esc(hostname) + ' / ' + esc(snapshot) + '</strong></div>';

        // Files section
        html += '<h3 style="margin:0.75rem 0 0.5rem;font-size:0.9rem">&#x1F4C1; Files</h3>';
        if (filesData && filesData.items && filesData.items.length > 0) {
            html += _buildItemTable(hostname, snapshot, filesData.items, '', 'files');
            html += '<div class="form-actions" style="margin-top:0.5rem">' +
                '<button class="btn btn-sm btn-success" onclick="downloadChoice(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'files\')">Download All Files</button> ' +
                '<button class="btn btn-sm btn-primary" onclick="restoreItem(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'\')">Restore All Files</button>' +
            '</div>';
        } else {
            html += '<p class="text-muted" style="font-size:0.82rem">No file backups in this snapshot</p>';
        }

        // SQL section
        html += '<h3 style="margin:1.25rem 0 0.5rem;font-size:0.9rem">&#x1F5C3; Databases</h3>';
        if (sqlData && sqlData.items && sqlData.items.length > 0) {
            html += _buildItemTable(hostname, snapshot, sqlData.items, '', 'sql');
            html += '<div class="form-actions" style="margin-top:0.5rem">' +
                '<button class="btn btn-sm btn-success" onclick="downloadChoice(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'sql\')">Download All Databases</button> ' +
                '<button class="btn btn-sm btn-primary" onclick="restoreItem(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'__sql__\')">Restore All Databases</button>' +
            '</div>';
        } else {
            html += '<p class="text-muted" style="font-size:0.82rem">No database backups in this snapshot</p>';
        }

        html += '<div class="form-actions" style="margin-top:1rem">' +
            '<button class="btn" onclick="viewSnapshots(\'' + esc(hostname) + '\')">Back to Snapshots</button>' +
        '</div>';

        openModal('Browse: ' + hostname + ' / ' + snapshot, html);
        return;
    }

    // Browsing inside files/ or sql/
    var isSql = subPath.indexOf('__sql__') === 0 || _browsePath.indexOf('__sql__') === 0;
    var apiSubPath = subPath;
    if (isSql) apiSubPath = subPath.replace('__sql__', 'sql');
    var section = isSql ? 'sql' : 'files';

    var url = '/api/browse/' + hostname + '/' + snapshot;
    if (apiSubPath) url += '/' + apiSubPath;

    var data = await apiGet(url);
    if (!data) { toast('Failed to browse snapshot', 'error'); return; }

    var breadcrumb = _buildBreadcrumb(hostname, snapshot, data.path || '', section);

    var rows = _buildItemTable(hostname, snapshot, data.items || [], _browsePath, section);
    if (!data.items || data.items.length === 0) {
        rows = '<table class="browse-table"><tbody><tr><td class="empty">Empty directory</td></tr></tbody></table>';
    }

    var dlPath = section + (_browsePath ? '/' + _browsePath : '');
    if (isSql) dlPath = 'sql' + (_browsePath.replace('__sql__', '') ? '/' + _browsePath.replace('__sql__/', '').replace('__sql__', '') : '');

    var html = breadcrumb + rows +
        '<div class="form-actions" style="margin-top:1rem">' +
            '<button class="btn btn-success" onclick="downloadChoice(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(dlPath) + '\')">Download This Folder</button> ' +
            '<button class="btn btn-primary" onclick="restoreItem(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(_browsePath) + '\')">Restore This Folder</button> ' +
            '<button class="btn" onclick="browseSnapshot(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\')">Back to Root</button> ' +
            '<button class="btn" onclick="viewSnapshots(\'' + esc(hostname) + '\')">Back to Snapshots</button>' +
        '</div>';

    openModal('Browse: ' + hostname + ' / ' + snapshot, html);
}

function _buildItemTable(hostname, snapshot, items, currentPath, section) {
    if (!items || items.length === 0) return '';
    var dirs = items.filter(function(i) { return i.type === 'dir'; });
    var files = items.filter(function(i) { return i.type !== 'dir'; });
    var sorted = dirs.concat(files);

    var rows = sorted.map(function(item) {
        var icon = item.type === 'dir' ? '&#x1F4C1;' : (section === 'sql' ? '&#x1F5C3;' : '&#x1F4C4;');
        var clickPath = currentPath ? currentPath + '/' + item.name : item.name;
        var dlPath = section + '/' + (currentPath ? currentPath + '/' : '') + item.name;
        // For sql section, use __sql__ prefix in restore path so restoreItem knows it's a DB
        var restorePath = clickPath;
        if (section === 'sql') {
            dlPath = 'sql/' + item.name;
            restorePath = '__sql__/' + item.name;
        }
        var nameCell = '';
        if (item.type === 'dir') {
            nameCell = '<a href="#" onclick="browseSnapshot(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(clickPath) + '\');return false">' + icon + ' ' + esc(item.name) + '</a>';
        } else {
            nameCell = icon + ' ' + esc(item.name);
        }
        return '<tr>' +
            '<td>' + nameCell + '</td>' +
            '<td class="text-muted">' + esc(item.size) + '</td>' +
            '<td>' +
                '<button class="btn btn-sm btn-success" onclick="downloadChoice(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(dlPath) + '\')">Download</button> ' +
                '<button class="btn btn-sm" onclick="restoreItem(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(restorePath) + '\')">Restore</button>' +
            '</td></tr>';
    }).join('');

    return '<table class="browse-table">' +
        '<thead><tr><th>Name</th><th>Size</th><th>Actions</th></tr></thead>' +
        '<tbody>' + rows + '</tbody></table>';
}

function _buildBreadcrumb(hostname, snapshot, relPath, section) {
    var parts = ['<a href="#" onclick="browseSnapshot(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\');return false">' + esc(hostname) + ' / ' + esc(snapshot) + '</a>'];
    if (section === 'sql') {
        parts.push('<strong>sql</strong>');
    } else if (relPath && relPath !== 'files') {
        var cleanPath = relPath.replace(/^files\/?/, '');
        if (cleanPath) {
            var segments = cleanPath.split('/');
            var accumulated = '';
            for (var i = 0; i < segments.length; i++) {
                accumulated += (accumulated ? '/' : '') + segments[i];
                if (i < segments.length - 1) {
                    parts.push('<a href="#" onclick="browseSnapshot(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(accumulated) + '\');return false">' + esc(segments[i]) + '</a>');
                } else {
                    parts.push('<strong>' + esc(segments[i]) + '</strong>');
                }
            }
        }
    }
    return '<div class="breadcrumb">' + parts.join(' / ') + '</div>';
}

function downloadSnapshot(hostname, snapshot, subPath, format) {
    format = format || 'tar.gz';
    var url = API_BASE + '/api/download/' + hostname + '/' + snapshot;
    if (subPath) url += '/' + subPath;
    url += '?format=' + format;
    window.open(url, '_blank');
    toast('Download started (' + format + ')', 'info');
}

function downloadChoice(hostname, snapshot, subPath) {
    var dlPath = subPath || 'files';
    var displayPath = subPath ? subPath.replace(/^files\/?/, '') || '/' : '/';
    var html = '<div class="edit-server-form">' +
        '<p>Download <strong>' + esc(displayPath) + '</strong> from snapshot <strong>' + esc(snapshot) + '</strong></p>' +
        '<div class="form-group">' +
            '<label>Format</label>' +
            '<select id="dl-format">' +
                '<option value="tar.gz">tar.gz (recommended)</option>' +
                '<option value="zip">zip</option>' +
            '</select>' +
        '</div>' +
        '<div class="form-actions">' +
            '<button class="btn btn-success" onclick="downloadSnapshot(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(dlPath) + '\',document.getElementById(\'dl-format\').value);closeModal()">Download</button>' +
            '<button class="btn" onclick="closeModal()">Cancel</button>' +
        '</div>' +
    '</div>';
    openModal('Download: ' + hostname, html);
}

function restoreItem(hostname, snapshot, itemPath) {
    // Detect if this is a database restore
    var isDb = itemPath && itemPath.indexOf('__sql__') === 0;
    var displayPath = itemPath || '/ (all files)';
    var mode = 'files-only';

    if (isDb) {
        var sqlItem = itemPath.replace('__sql__/', '').replace('__sql__', '');
        displayPath = sqlItem ? 'sql/' + sqlItem : 'sql/ (all databases)';
        mode = 'db-only';
    }

    var typeLabel = isDb ? 'database backup' : 'files';

    var html = '<div class="edit-server-form">' +
        '<p>Restore <strong>' + esc(displayPath) + '</strong> from snapshot <strong>' + esc(snapshot) + '</strong> to server <strong>' + esc(hostname) + '</strong></p>' +
        '<div class="form-group">' +
            '<label>Restore as</label>' +
            '<select id="restore-format">' +
                '<option value="files">Files (copy directly)</option>' +
                '<option value="tar.gz">tar.gz archive</option>' +
                '<option value="zip">zip archive</option>' +
            '</select>' +
        '</div>' +
        '<div class="form-group">' +
            '<label>Target Directory <span class="text-muted">(on the server, leave empty for default)</span></label>' +
            '<input type="text" id="restore-target" placeholder="/home/timemachine/restores" style="width:100%;box-sizing:border-box;padding:0.5rem 0.7rem;background:var(--bg-input);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text);font-size:0.85rem">' +
        '</div>' +
        '<div class="form-actions">' +
            '<button class="btn btn-primary" onclick="doRestore(\'' + esc(hostname) + '\',\'' + esc(snapshot) + '\',\'' + esc(itemPath) + '\',\'' + esc(mode) + '\')">Restore to Server</button>' +
            '<button class="btn" onclick="closeModal()">Cancel</button>' +
        '</div>' +
    '</div>';
    openModal('Restore ' + typeLabel + ': ' + hostname, html);
}

async function doRestore(hostname, snapshot, itemPath, mode) {
    var format = document.getElementById('restore-format').value;
    var target = document.getElementById('restore-target').value.trim();

    // Handle __sql__ prefix: clean path for API
    var isDb = itemPath && itemPath.indexOf('__sql__') === 0;
    var cleanPath = itemPath;
    if (isDb) {
        cleanPath = itemPath.replace('__sql__/', '').replace('__sql__', '');
    }

    var body = { snapshot: snapshot, mode: mode };
    if (cleanPath) body.path = cleanPath;
    if (target) body.target = target;
    if (format !== 'files') body.format = format;

    closeModal();
    var result = await apiPost('/api/restore/' + hostname, body);
    if (result && result.status === 'started') {
        toast('Restore started for ' + hostname + ' (' + format + ')', 'success');
        setTimeout(refreshRestores, 1500);
    } else {
        toast('Failed to start restore', 'error');
    }
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
        refreshRestores(),
        refreshHistory().then(refreshServers),
        refreshSSHKey()
    ]);
}

refreshAll();
refreshSettings();
refreshExcludes();
refreshArchived();
setInterval(refreshAll, REFRESH_INTERVAL);
setInterval(refreshArchived, REFRESH_INTERVAL);
