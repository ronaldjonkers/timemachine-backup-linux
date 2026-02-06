/* ============================================================
   TimeMachine Backup - Dashboard JavaScript
   ============================================================ */

const API_BASE = window.location.origin;
const REFRESH_INTERVAL = 10000; // 10 seconds

/* ============================================================
   API HELPERS
   ============================================================ */

async function apiGet(endpoint) {
    try {
        const resp = await fetch(`${API_BASE}${endpoint}`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        return await resp.json();
    } catch (e) {
        console.error(`API GET ${endpoint}:`, e);
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
   STATUS
   ============================================================ */

function formatUptime(seconds) {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h ${mins}m`;
    if (hours > 0) return `${hours}h ${mins}m`;
    return `${mins}m`;
}

async function refreshStatus() {
    const data = await apiGet('/api/status');
    const badge = document.getElementById('service-status');
    const uptimeEl = document.getElementById('uptime');
    const hostnameEl = document.getElementById('hostname');
    const activeEl = document.getElementById('active-jobs');

    if (data) {
        badge.textContent = 'Running';
        badge.className = 'status-badge status-running';
        uptimeEl.textContent = formatUptime(data.uptime || 0);
        hostnameEl.textContent = data.hostname || '--';

        const running = (data.processes || []).filter(p => p.status === 'running').length;
        activeEl.textContent = running;
    } else {
        badge.textContent = 'Offline';
        badge.className = 'status-badge status-stopped';
        uptimeEl.textContent = '--';
        activeEl.textContent = '0';
    }

    document.getElementById('refresh-time').textContent =
        `Last refresh: ${new Date().toLocaleTimeString()}`;
}

/* ============================================================
   PROCESSES
   ============================================================ */

async function refreshProcesses() {
    const data = await apiGet('/api/processes');
    const tbody = document.getElementById('processes-body');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="empty">No processes</td></tr>';
        return;
    }

    tbody.innerHTML = data.map(proc => {
        const statusClass = proc.status || 'unknown';
        const canKill = proc.status === 'running';
        return `<tr>
            <td><strong>${esc(proc.hostname)}</strong></td>
            <td>${proc.pid}</td>
            <td>${esc(proc.mode)}</td>
            <td>${esc(proc.started)}</td>
            <td><span class="status-cell ${statusClass}">${esc(proc.status)}</span></td>
            <td>
                ${canKill
                    ? `<button class="btn btn-sm btn-danger" onclick="killBackup('${esc(proc.hostname)}')">Kill</button>`
                    : '--'}
            </td>
        </tr>`;
    }).join('');
}

/* ============================================================
   SERVERS
   ============================================================ */

async function refreshServers() {
    const data = await apiGet('/api/servers');
    const tbody = document.getElementById('servers-body');
    const countEl = document.getElementById('server-count');

    if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="3" class="empty">No servers configured</td></tr>';
        countEl.textContent = '0';
        return;
    }

    countEl.textContent = data.length;

    tbody.innerHTML = data.map(srv => {
        return `<tr>
            <td><strong>${esc(srv.hostname)}</strong></td>
            <td>${esc(srv.options) || '<em style="color:var(--text-muted)">default</em>'}</td>
            <td>
                <button class="btn btn-sm btn-success" onclick="startBackupFor('${esc(srv.hostname)}')">Backup</button>
                <button class="btn btn-sm" onclick="viewSnapshots('${esc(srv.hostname)}')">Snapshots</button>
                <button class="btn btn-sm btn-danger" onclick="removeServer('${esc(srv.hostname)}')">Remove</button>
            </td>
        </tr>`;
    }).join('');
}

/* ============================================================
   SSH KEY
   ============================================================ */

async function refreshSSHKey() {
    const data = await apiGet('/api/ssh-key');
    const el = document.getElementById('ssh-key');
    const urlEl = document.getElementById('ssh-key-url');

    if (data && data.ssh_public_key) {
        el.textContent = data.ssh_public_key;
        urlEl.textContent = `curl -s ${API_BASE}/api/ssh-key/raw`;
    } else {
        el.textContent = 'SSH key not available (service may be offline)';
    }
}

function copySSHKey() {
    const key = document.getElementById('ssh-key').textContent;
    if (key && !key.startsWith('SSH key not')) {
        navigator.clipboard.writeText(key).then(() => {
            const btn = event.target;
            btn.textContent = 'Copied!';
            setTimeout(() => { btn.textContent = 'Copy'; }, 2000);
        });
    }
}

/* ============================================================
   ACTIONS
   ============================================================ */

async function startBackup() {
    const hostname = document.getElementById('backup-hostname').value.trim();
    const mode = document.getElementById('backup-mode').value;

    if (!hostname) {
        alert('Please enter a hostname');
        return;
    }

    const result = await apiPost(`/api/backup/${hostname}${mode}`);
    if (result) {
        document.getElementById('backup-hostname').value = '';
        setTimeout(refreshProcesses, 1000);
    }
}

async function startBackupFor(hostname) {
    await apiPost(`/api/backup/${hostname}`);
    setTimeout(refreshProcesses, 1000);
}

async function killBackup(hostname) {
    if (!confirm(`Kill backup for ${hostname}?`)) return;
    await apiDelete(`/api/backup/${hostname}`);
    setTimeout(refreshProcesses, 1000);
}

async function addServer() {
    const hostname = document.getElementById('add-server-hostname').value.trim();
    const options = document.getElementById('add-server-options').value;

    if (!hostname) {
        alert('Please enter a hostname');
        return;
    }

    const result = await apiPost('/api/servers', { hostname, options });
    if (result && result.status === 'added') {
        document.getElementById('add-server-hostname').value = '';
        document.getElementById('add-server-options').value = '';
        refreshServers();
    } else if (result && result.error) {
        alert(result.error);
    }
}

async function removeServer(hostname) {
    if (!confirm(`Remove server ${hostname} from backup list?`)) return;
    const result = await apiDelete(`/api/servers/${hostname}`);
    if (result) {
        refreshServers();
    }
}

async function viewSnapshots(hostname) {
    const data = await apiGet(`/api/snapshots/${hostname}`);
    if (!data || data.length === 0) {
        alert(`No snapshots found for ${hostname}`);
        return;
    }

    const lines = data.map(s =>
        `${s.date}  size=${s.size}  files=${s.has_files}  sql=${s.has_sql}`
    ).join('\n');

    alert(`Snapshots for ${hostname}:\n\n${lines}`);
}

/* ============================================================
   UTILITIES
   ============================================================ */

function esc(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

/* ============================================================
   INITIALIZATION
   ============================================================ */

async function refreshAll() {
    await Promise.all([
        refreshStatus(),
        refreshProcesses(),
        refreshServers(),
        refreshSSHKey()
    ]);
}

// Initial load
refreshAll();

// Auto-refresh
setInterval(refreshAll, REFRESH_INTERVAL);
