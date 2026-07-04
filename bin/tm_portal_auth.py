#!/usr/bin/env python3
# ============================================================
# TimeMachine Backup - Portal Authentication Module
# ============================================================
# Sessions + WebAuthn passkeys + registration tokens + audit log.
#
# Used by tm-api-server.py (imported) and by tmctl (CLI mode):
#   python3 tm_portal_auth.py create-admin <username>
#   python3 tm_portal_auth.py new-link <username>
#   python3 tm_portal_auth.py list | revoke <username> | status
#
# Python 3.6-compatible. Passkey verification requires the 'fido2'
# package (pip3 install fido2, needs Python 3.8+). Without it the
# portal keeps running in legacy mode (nginx Basic Auth in front).
# ============================================================

import os
import sys
import json
import time
import base64
import sqlite3
import hashlib
import secrets
import threading

# --- optional fido2 (passkeys) ------------------------------
FIDO2_AVAILABLE = False
FIDO2_ERROR = ''
try:
    from fido2.server import Fido2Server
    from fido2.webauthn import (
        PublicKeyCredentialRpEntity, PublicKeyCredentialUserEntity,
        ResidentKeyRequirement, UserVerificationRequirement,
        AttestedCredentialData,
    )
    from fido2 import features as _fido2_features
    try:
        _fido2_features.webauthn_json_mapping.enabled = True
    except Exception:
        pass
    FIDO2_AVAILABLE = True
except Exception as e:  # ImportError or SyntaxError on very old Python
    FIDO2_ERROR = str(e)

# --- module state -------------------------------------------
_STATE_DIR = None
_LOG_DIR = None
_ENV = {}
_pending = {}            # nonce -> (expires_epoch, fido2_state, meta)
_pending_lock = threading.Lock()
_audit_lock = threading.Lock()

SESSION_HOURS_DEFAULT = 24
PENDING_TTL = 300        # seconds a begin() challenge stays valid
REG_TOKEN_HOURS = 72


def b64u_enc(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def b64u_dec(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))


def init(state_dir, log_dir, env):
    """Called once by the API server (or CLI) before use."""
    global _STATE_DIR, _LOG_DIR, _ENV
    _STATE_DIR = state_dir
    _LOG_DIR = log_dir
    _ENV = env or {}
    _init_db()


def _db_path():
    return os.path.join(_STATE_DIR, 'portal.db')


def _db():
    conn = sqlite3.connect(_db_path(), timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def _init_db():
    conn = _db()
    try:
        conn.executescript('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                role TEXT NOT NULL DEFAULT 'admin',
                created_at INTEGER NOT NULL,
                disabled INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS credentials (
                id INTEGER PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id),
                cred_id TEXT UNIQUE NOT NULL,
                cred_data BLOB NOT NULL,
                name TEXT,
                created_at INTEGER NOT NULL,
                last_used INTEGER
            );
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY,
                token_hash TEXT UNIQUE NOT NULL,
                user_id INTEGER NOT NULL REFERENCES users(id),
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                ip TEXT, ua TEXT
            );
            CREATE TABLE IF NOT EXISTS reg_tokens (
                id INTEGER PRIMARY KEY,
                token_hash TEXT UNIQUE NOT NULL,
                user_id INTEGER NOT NULL REFERENCES users(id),
                expires_at INTEGER NOT NULL,
                used_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS customers (
                id INTEGER PRIMARY KEY,
                name TEXT UNIQUE NOT NULL,
                created_at INTEGER NOT NULL,
                disabled INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS customer_servers (
                id INTEGER PRIMARY KEY,
                customer_id INTEGER NOT NULL REFERENCES customers(id),
                hostname TEXT NOT NULL,
                UNIQUE(customer_id, hostname)
            );
        ''')
        # users.customer_id: which customer (organization) a user belongs to
        cols = [r[1] for r in conn.execute('PRAGMA table_info(users)')]
        if 'customer_id' not in cols:
            conn.execute('ALTER TABLE users ADD COLUMN customer_id INTEGER')

        # Migration from v3.9.0: per-user server assignments become a
        # customer (named after the user) with that user as its member.
        legacy = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='server_assignments'"
        ).fetchone()
        if legacy:
            now = int(time.time())
            rows = conn.execute(
                'SELECT DISTINCT u.id AS uid, u.username FROM server_assignments sa '
                'JOIN users u ON u.id = sa.user_id').fetchall()
            for row in rows:
                cust = conn.execute('SELECT id FROM customers WHERE name = ?',
                                    (row['username'],)).fetchone()
                if cust is None:
                    conn.execute('INSERT INTO customers (name, created_at) VALUES (?, ?)',
                                 (row['username'], now))
                    cust_id = conn.execute('SELECT id FROM customers WHERE name = ?',
                                           (row['username'],)).fetchone()['id']
                else:
                    cust_id = cust['id']
                conn.execute('UPDATE users SET customer_id = ? WHERE id = ?',
                             (cust_id, row['uid']))
                for h in conn.execute('SELECT hostname FROM server_assignments WHERE user_id = ?',
                                      (row['uid'],)).fetchall():
                    conn.execute(
                        'INSERT OR IGNORE INTO customer_servers (customer_id, hostname) VALUES (?, ?)',
                        (cust_id, h['hostname']))
            conn.execute('DROP TABLE server_assignments')
        conn.commit()
    finally:
        conn.close()


def _sha256(s):
    if isinstance(s, str):
        s = s.encode()
    return hashlib.sha256(s).hexdigest()


# ============================================================
# CONFIG / MODE
# ============================================================

def portal_domain():
    return (_ENV.get('TM_PORTAL_DOMAIN') or '').strip()


def portal_origin():
    override = (_ENV.get('TM_PORTAL_ORIGIN') or '').strip()
    if override:
        return override
    d = portal_domain()
    return 'https://{0}'.format(d) if d else ''


def passkey_configured():
    """fido2 present and a domain configured — passkeys CAN be used."""
    return FIDO2_AVAILABLE and bool(portal_domain())


def passkey_mode():
    """Passkeys ENFORCED: at least one active user has a credential."""
    if not passkey_configured():
        return False
    conn = _db()
    try:
        row = conn.execute(
            'SELECT COUNT(*) AS n FROM credentials c '
            'JOIN users u ON u.id = c.user_id WHERE u.disabled = 0').fetchone()
        return row['n'] > 0
    finally:
        conn.close()


def _fido2_server():
    rp = PublicKeyCredentialRpEntity(id=portal_domain(), name='TimeMachine Backup')
    expected = portal_origin()
    return Fido2Server(rp, verify_origin=lambda o: o == expected)


def _load_credentials(user_id=None):
    conn = _db()
    try:
        if user_id is None:
            rows = conn.execute(
                'SELECT c.* FROM credentials c JOIN users u ON u.id = c.user_id '
                'WHERE u.disabled = 0').fetchall()
        else:
            rows = conn.execute(
                'SELECT * FROM credentials WHERE user_id = ?', (user_id,)).fetchall()
        return [(row['id'], row['user_id'], AttestedCredentialData(row['cred_data']))
                for row in rows]
    finally:
        conn.close()


# ============================================================
# PENDING CHALLENGES
# ============================================================

def _pending_put(state, meta):
    nonce = secrets.token_urlsafe(24)
    now = time.time()
    with _pending_lock:
        # purge expired
        for k in [k for k, v in _pending.items() if v[0] < now]:
            del _pending[k]
        _pending[nonce] = (now + PENDING_TTL, state, meta)
    return nonce


def _pending_pop(nonce):
    with _pending_lock:
        entry = _pending.pop(nonce, None)
    if entry is None or entry[0] < time.time():
        return None
    return entry[1], entry[2]


# ============================================================
# REGISTRATION (one-time token -> passkey)
# ============================================================

def _valid_reg_token(token):
    conn = _db()
    try:
        row = conn.execute(
            'SELECT t.*, u.username, u.role, u.disabled FROM reg_tokens t '
            'JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?',
            (_sha256(token),)).fetchone()
        if row is None or row['used_at'] is not None:
            return None
        if row['expires_at'] < int(time.time()) or row['disabled']:
            return None
        return row
    finally:
        conn.close()


def register_begin(token):
    """Returns (options_dict, nonce) or raises ValueError."""
    if not passkey_configured():
        raise ValueError('Passkeys not available on this server')
    row = _valid_reg_token(token)
    if row is None:
        raise ValueError('Invalid or expired registration link')
    user = PublicKeyCredentialUserEntity(
        id=str(row['user_id']).encode(),
        name=row['username'], display_name=row['username'])
    existing = [c[2] for c in _load_credentials(row['user_id'])]
    options, state = _fido2_server().register_begin(
        user, credentials=existing,
        resident_key_requirement=ResidentKeyRequirement.REQUIRED,
        user_verification=UserVerificationRequirement.PREFERRED)
    nonce = _pending_put(state, {'user_id': row['user_id'], 'token_hash': _sha256(token)})
    return json.loads(json.dumps(dict(options))), nonce


def register_complete(token, nonce, response, key_name, ip=''):
    """Verifies attestation, stores credential, burns the token."""
    row = _valid_reg_token(token)
    if row is None:
        raise ValueError('Invalid or expired registration link')
    popped = _pending_pop(nonce)
    if popped is None:
        raise ValueError('Challenge expired — try again')
    state, meta = popped
    if meta.get('user_id') != row['user_id']:
        raise ValueError('Token/challenge mismatch')

    auth_data = _fido2_server().register_complete(state, response=response)
    cred = auth_data.credential_data

    now = int(time.time())
    conn = _db()
    try:
        conn.execute(
            'INSERT INTO credentials (user_id, cred_id, cred_data, name, created_at) '
            'VALUES (?, ?, ?, ?, ?)',
            (row['user_id'], b64u_enc(cred.credential_id), bytes(cred),
             (key_name or 'passkey')[:64], now))
        conn.execute('UPDATE reg_tokens SET used_at = ? WHERE token_hash = ?',
                     (now, _sha256(token)))
        conn.commit()
    finally:
        conn.close()
    audit('passkey_register', row['username'], 'key={0}'.format(key_name or 'passkey'), ip)
    return {'username': row['username'], 'role': row['role']}


# ============================================================
# LOGIN (usernameless, discoverable credentials)
# ============================================================

def login_begin():
    if not passkey_configured():
        raise ValueError('Passkeys not available on this server')
    options, state = _fido2_server().authenticate_begin(
        user_verification=UserVerificationRequirement.PREFERRED)
    nonce = _pending_put(state, {})
    return json.loads(json.dumps(dict(options))), nonce


def login_complete(nonce, response, ip='', ua=''):
    """Returns (session_token, user_dict) or raises ValueError."""
    popped = _pending_pop(nonce)
    if popped is None:
        raise ValueError('Challenge expired — try again')
    state, _meta = popped

    creds = _load_credentials()
    result = _fido2_server().authenticate_complete(
        state, [c[2] for c in creds], response=response)

    matched = None
    for cred_pk_id, user_id, cred_obj in creds:
        if cred_obj.credential_id == result.credential_id:
            matched = (cred_pk_id, user_id)
            break
    if matched is None:
        raise ValueError('Unknown credential')

    now = int(time.time())
    hours = int(_ENV.get('TM_SESSION_HOURS') or SESSION_HOURS_DEFAULT)
    token = secrets.token_urlsafe(32)
    conn = _db()
    try:
        user = conn.execute('SELECT * FROM users WHERE id = ? AND disabled = 0',
                            (matched[1],)).fetchone()
        if user is None:
            raise ValueError('User disabled')
        conn.execute('UPDATE credentials SET last_used = ? WHERE id = ?', (now, matched[0]))
        conn.execute(
            'INSERT INTO sessions (token_hash, user_id, created_at, expires_at, ip, ua) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (_sha256(token), matched[1], now, now + hours * 3600, ip[:64], ua[:128]))
        # opportunistic cleanup of expired sessions
        conn.execute('DELETE FROM sessions WHERE expires_at < ?', (now,))
        conn.commit()
        udict = {'username': user['username'], 'role': user['role']}
    finally:
        conn.close()
    audit('login_ok', udict['username'], '', ip)
    return token, udict


# ============================================================
# SESSIONS
# ============================================================

def get_session(token):
    """Returns user dict or None. Extends the session when it is past
    half its lifetime (sliding renewal)."""
    if not token:
        return None
    now = int(time.time())
    conn = _db()
    try:
        row = conn.execute(
            'SELECT s.expires_at, s.created_at, u.username, u.role, u.disabled '
            'FROM sessions s JOIN users u ON u.id = s.user_id '
            'WHERE s.token_hash = ?', (_sha256(token),)).fetchone()
        if row is None or row['expires_at'] < now or row['disabled']:
            return None
        hours = int(_ENV.get('TM_SESSION_HOURS') or SESSION_HOURS_DEFAULT)
        if row['expires_at'] - now < (hours * 3600) // 2:
            conn.execute('UPDATE sessions SET expires_at = ? WHERE token_hash = ?',
                         (now + hours * 3600, _sha256(token)))
            conn.commit()
        return {'username': row['username'], 'role': row['role']}
    finally:
        conn.close()


def destroy_session(token):
    if not token:
        return
    conn = _db()
    try:
        conn.execute('DELETE FROM sessions WHERE token_hash = ?', (_sha256(token),))
        conn.commit()
    finally:
        conn.close()


# ============================================================
# USER / TOKEN MANAGEMENT (CLI)
# ============================================================

def create_user(username, role='admin'):
    conn = _db()
    try:
        conn.execute('INSERT INTO users (username, role, created_at) VALUES (?, ?, ?)',
                     (username, role, int(time.time())))
        conn.commit()
    finally:
        conn.close()


def new_reg_token(username):
    """Creates a one-time registration token for an existing user."""
    conn = _db()
    try:
        user = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        if user is None:
            raise ValueError('No such user: {0}'.format(username))
        token = secrets.token_urlsafe(32)
        conn.execute(
            'INSERT INTO reg_tokens (token_hash, user_id, expires_at) VALUES (?, ?, ?)',
            (_sha256(token), user['id'], int(time.time()) + REG_TOKEN_HOURS * 3600))
        conn.commit()
        return token
    finally:
        conn.close()


# ============================================================
# CUSTOMERS (organizations with users and server assignments)
# ============================================================

def create_customer(name, hostnames=None):
    conn = _db()
    try:
        if conn.execute('SELECT 1 FROM customers WHERE name = ?', (name,)).fetchone():
            raise ValueError('Customer already exists: {0}'.format(name))
        conn.execute('INSERT INTO customers (name, created_at) VALUES (?, ?)',
                     (name, int(time.time())))
        conn.commit()
    finally:
        conn.close()
    if hostnames:
        set_customer_servers(name, hostnames)


def customer_exists(name):
    conn = _db()
    try:
        return conn.execute('SELECT 1 FROM customers WHERE name = ?',
                            (name,)).fetchone() is not None
    finally:
        conn.close()


def set_customer_servers(name, hostnames):
    """Replace the server assignments of a customer."""
    conn = _db()
    try:
        cust = conn.execute('SELECT * FROM customers WHERE name = ?', (name,)).fetchone()
        if cust is None:
            raise ValueError('No such customer: {0}'.format(name))
        conn.execute('DELETE FROM customer_servers WHERE customer_id = ?', (cust['id'],))
        for h in hostnames or []:
            h = (h or '').strip()
            if h:
                conn.execute(
                    'INSERT OR IGNORE INTO customer_servers (customer_id, hostname) VALUES (?, ?)',
                    (cust['id'], h))
        conn.commit()
    finally:
        conn.close()


def get_customer_servers(name):
    conn = _db()
    try:
        rows = conn.execute(
            'SELECT cs.hostname FROM customer_servers cs '
            'JOIN customers c ON c.id = cs.customer_id WHERE c.name = ? '
            'ORDER BY cs.hostname', (name,)).fetchall()
        return [r['hostname'] for r in rows]
    finally:
        conn.close()


def add_customer_user(customer_name, username):
    """Create a user (role=customer) inside a customer organization."""
    conn = _db()
    try:
        cust = conn.execute('SELECT * FROM customers WHERE name = ?',
                            (customer_name,)).fetchone()
        if cust is None:
            raise ValueError('No such customer: {0}'.format(customer_name))
        existing = conn.execute('SELECT * FROM users WHERE username = ?',
                                (username,)).fetchone()
        if existing is not None:
            raise ValueError('User already exists: {0}'.format(username))
        conn.execute(
            'INSERT INTO users (username, role, created_at, customer_id) VALUES (?, ?, ?, ?)',
            (username, 'customer', int(time.time()), cust['id']))
        conn.commit()
    finally:
        conn.close()


def revoke_customer(name):
    """Disable a customer and revoke ALL its users (sessions + passkeys)."""
    conn = _db()
    try:
        cust = conn.execute('SELECT * FROM customers WHERE name = ?', (name,)).fetchone()
        if cust is None:
            raise ValueError('No such customer: {0}'.format(name))
        users = [r['username'] for r in conn.execute(
            'SELECT username FROM users WHERE customer_id = ?', (cust['id'],)).fetchall()]
        conn.execute('UPDATE customers SET disabled = 1 WHERE id = ?', (cust['id'],))
        conn.commit()
    finally:
        conn.close()
    for u in users:
        revoke_user(u)
    return users


def list_customers():
    """Customers with their servers and users (incl. passkey counts)."""
    conn = _db()
    try:
        custs = [dict(r) for r in conn.execute(
            'SELECT id, name, disabled, created_at FROM customers ORDER BY name').fetchall()]
        for c in custs:
            c['servers'] = [r['hostname'] for r in conn.execute(
                'SELECT hostname FROM customer_servers WHERE customer_id = ? ORDER BY hostname',
                (c['id'],)).fetchall()]
            c['users'] = [dict(r) for r in conn.execute(
                'SELECT u.username, u.disabled, COUNT(cr.id) AS passkeys '
                'FROM users u LEFT JOIN credentials cr ON cr.user_id = u.id '
                'WHERE u.customer_id = ? GROUP BY u.id ORDER BY u.username',
                (c['id'],)).fetchall()]
            del c['id']
        return custs
    finally:
        conn.close()


def get_user_servers(username):
    """Hostnames a user may access, via their customer (empty = none).
    Users of a disabled customer get no access."""
    conn = _db()
    try:
        rows = conn.execute(
            'SELECT cs.hostname FROM customer_servers cs '
            'JOIN customers c ON c.id = cs.customer_id '
            'JOIN users u ON u.customer_id = c.id '
            'WHERE u.username = ? AND c.disabled = 0 '
            'ORDER BY cs.hostname', (username,)).fetchall()
        return [r['hostname'] for r in rows]
    finally:
        conn.close()


def user_exists(username):
    conn = _db()
    try:
        return conn.execute('SELECT 1 FROM users WHERE username = ?',
                            (username,)).fetchone() is not None
    finally:
        conn.close()


def send_invite_email(username, email, link):
    """Send a registration link by email via the TM_SMTP_* relay.
    Returns True on success; raises ValueError with a reason on failure."""
    import smtplib
    from email.mime.text import MIMEText

    host = (_ENV.get('TM_SMTP_HOST') or '').strip()
    if not host:
        raise ValueError('No SMTP relay configured (TM_SMTP_HOST in .env)')
    port = int(_ENV.get('TM_SMTP_PORT') or 587)
    user = _ENV.get('TM_SMTP_USER') or ''
    pw = _ENV.get('TM_SMTP_PASS') or ''
    sender = _ENV.get('TM_SMTP_FROM') or user or 'backup@localhost'

    body = ('Hello {0},\n\n'
            'You have been invited to the TimeMachine Backup portal.\n'
            'Open the link below to create your passkey (valid {1} hours):\n\n'
            '  {2}\n\n'
            'After creating the passkey you can sign in and access your backups.\n'
            .format(username, REG_TOKEN_HOURS, link))
    msg = MIMEText(body)
    msg['Subject'] = '[TimeMachine] Backup portal invitation'
    msg['From'] = sender
    msg['To'] = email

    try:
        if port == 465:
            s = smtplib.SMTP_SSL(host, port, timeout=30)
        else:
            s = smtplib.SMTP(host, port, timeout=30)
            if (_ENV.get('TM_SMTP_TLS') or 'true') == 'true':
                s.starttls()
        if user and pw:
            s.login(user, pw)
        s.sendmail(sender, [email], msg.as_string())
        s.quit()
    except Exception as e:
        raise ValueError('SMTP send failed: {0}'.format(e))
    audit('invite_sent', username, 'to={0}'.format(email))
    return True


def registration_link(token):
    d = portal_domain()
    base = 'https://{0}'.format(d) if d else 'https://<your-dashboard-domain>'
    return '{0}/register.html?token={1}'.format(base, token)


def revoke_user(username):
    """Disables a user and destroys all their sessions/credentials."""
    conn = _db()
    try:
        user = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        if user is None:
            raise ValueError('No such user: {0}'.format(username))
        conn.execute('UPDATE users SET disabled = 1 WHERE id = ?', (user['id'],))
        conn.execute('DELETE FROM sessions WHERE user_id = ?', (user['id'],))
        conn.execute('DELETE FROM credentials WHERE user_id = ?', (user['id'],))
        conn.commit()
    finally:
        conn.close()


def list_users():
    conn = _db()
    try:
        users = [dict(r) for r in conn.execute(
            'SELECT u.username, u.role, u.disabled, u.created_at, '
            '       cu.name AS customer, COUNT(c.id) AS passkeys '
            'FROM users u LEFT JOIN credentials c ON c.user_id = u.id '
            'LEFT JOIN customers cu ON cu.id = u.customer_id '
            'GROUP BY u.id ORDER BY u.username').fetchall()]
    finally:
        conn.close()
    for u in users:
        u['servers'] = get_user_servers(u['username'])
    return users


# ============================================================
# AUDIT LOG
# ============================================================

def audit(event, user, detail='', ip=''):
    """Append a JSON line to audit.log. Never raises."""
    try:
        line = json.dumps({
            'ts': time.strftime('%Y-%m-%d %H:%M:%S'),
            'event': event,
            'user': user or '-',
            'detail': detail or '',
            'ip': ip or '',
        })
        path = os.path.join(_LOG_DIR, 'audit.log')
        with _audit_lock:
            with open(path, 'a') as f:
                f.write(line + '\n')
    except Exception:
        pass


# ============================================================
# CLI
# ============================================================

def _cli_load_env(project_root):
    env = {}
    env_file = os.path.join(project_root, '.env')
    if os.path.isfile(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def _cli_main():
    project_root = os.environ.get('TM_PROJECT_ROOT') or \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = _cli_load_env(project_root)
    home = env.get('TM_HOME', '/home/timemachine')
    state = env.get('TM_STATE_DIR', os.path.join(home, 'state'))
    logs = env.get('TM_LOG_DIR', os.path.join(home, 'logs'))
    init(state, logs, env)

    args = sys.argv[1:]
    cmd = args[0] if args else 'status'

    def reg_url(token):
        d = portal_domain()
        base = 'https://{0}'.format(d) if d else 'https://<your-dashboard-domain>'
        return '{0}/register.html?token={1}'.format(base, token)

    def _invite_user(username, email):
        token = new_reg_token(username)
        link = reg_url(token)
        print('One-time registration link for {0} (valid {1}h):'.format(username, REG_TOKEN_HOURS))
        print('  {0}'.format(link))
        if email:
            try:
                send_invite_email(username, email, link)
                print('Invitation emailed to {0}'.format(email))
            except ValueError as e:
                print('Email NOT sent: {0}'.format(e))
                print('Send the link above manually.')

    if cmd == 'add-customer':
        # add-customer <name> <host1,host2,...> [email]
        # Creates the customer org; with an email, also creates a first
        # user with the same name and sends the invite.
        if len(args) < 3:
            print('Usage: tm_portal_auth.py add-customer <name> <host1,host2> [email]'); sys.exit(1)
        name, hosts = args[1], [h for h in args[2].split(',') if h.strip()]
        email = args[3] if len(args) > 3 else ''
        if not customer_exists(name):
            create_customer(name)
        set_customer_servers(name, hosts)
        print('Customer: {0}'.format(name))
        print('Servers : {0}'.format(', '.join(hosts)))
        if email or not user_exists(name):
            if not user_exists(name):
                add_customer_user(name, name)
                print('User    : {0} (first user of this customer)'.format(name))
            _invite_user(name, email)
    elif cmd == 'user-add':
        # user-add <customer> <username> [email]
        if len(args) < 3:
            print('Usage: tm_portal_auth.py user-add <customer> <username> [email]'); sys.exit(1)
        add_customer_user(args[1], args[2])
        print('User {0} added to customer {1}'.format(args[2], args[1]))
        _invite_user(args[2], args[3] if len(args) > 3 else '')
    elif cmd == 'set-servers':
        if len(args) < 3:
            print('Usage: tm_portal_auth.py set-servers <customer> <host1,host2,...>'); sys.exit(1)
        set_customer_servers(args[1], [h for h in args[2].split(',') if h.strip()])
        print('Servers for {0}: {1}'.format(args[1], ', '.join(get_customer_servers(args[1])) or '(none)'))
    elif cmd == 'revoke-customer':
        if len(args) < 2:
            print('Usage: tm_portal_auth.py revoke-customer <name>'); sys.exit(1)
        revoked = revoke_customer(args[1])
        print('Customer {0} disabled; {1} user(s) revoked: {2}'.format(
            args[1], len(revoked), ', '.join(revoked) or '-'))
    elif cmd == 'customers':
        custs = list_customers()
        if not custs:
            print('No customers yet. Create one with: tmctl customer add <name> <host1,host2> [email]')
        for c in custs:
            flag = ' (DISABLED)' if c['disabled'] else ''
            print('{0}{1}'.format(c['name'], flag))
            print('  servers: {0}'.format(', '.join(c['servers']) or '(none)'))
            for u in c['users']:
                uflag = ' (disabled)' if u['disabled'] else ''
                print('  user   : {0} passkeys={1}{2}'.format(u['username'], u['passkeys'], uflag))
    elif cmd == 'create-admin':
        if len(args) < 2:
            print('Usage: tm_portal_auth.py create-admin <username>'); sys.exit(1)
        create_user(args[1], 'admin')
        token = new_reg_token(args[1])
        print('Admin user created: {0}'.format(args[1]))
        print('One-time registration link (valid {0}h):'.format(REG_TOKEN_HOURS))
        print('  {0}'.format(reg_url(token)))
    elif cmd == 'new-link':
        if len(args) < 2:
            print('Usage: tm_portal_auth.py new-link <username>'); sys.exit(1)
        token = new_reg_token(args[1])
        print('One-time registration link for {0} (valid {1}h):'.format(args[1], REG_TOKEN_HOURS))
        print('  {0}'.format(reg_url(token)))
    elif cmd == 'revoke':
        if len(args) < 2:
            print('Usage: tm_portal_auth.py revoke <username>'); sys.exit(1)
        revoke_user(args[1])
        print('User {0} disabled; sessions and passkeys removed.'.format(args[1]))
    elif cmd == 'list':
        users = list_users()
        if not users:
            print('No portal users. Create one with: tmctl auth setup <username>')
        for u in users:
            flag = ' (DISABLED)' if u['disabled'] else ''
            servers = ', '.join(u.get('servers') or []) if u['role'] == 'customer' else 'ALL (admin)'
            print('{0:<20} role={1:<9} passkeys={2} servers={3}{4}'.format(
                u['username'], u['role'], u['passkeys'], servers, flag))
    elif cmd == 'status':
        print('fido2 library : {0}'.format(
            'available' if FIDO2_AVAILABLE else 'MISSING ({0})'.format(FIDO2_ERROR or 'pip3 install fido2')))
        print('portal domain : {0}'.format(portal_domain() or 'NOT SET (TM_PORTAL_DOMAIN in .env)'))
        print('passkey mode  : {0}'.format('ENFORCED' if passkey_mode() else 'off (legacy basic auth)'))
        print('users         : {0}'.format(len(list_users())))
    else:
        print('Unknown command: {0}'.format(cmd))
        print('Commands: create-admin <user> | add-customer <name> <hosts> [email] |')
        print('          user-add <customer> <user> [email] | set-servers <customer> <hosts> |')
        print('          revoke-customer <name> | customers | new-link <user> | revoke <user> | list | status')
        sys.exit(1)


if __name__ == '__main__':
    _cli_main()
