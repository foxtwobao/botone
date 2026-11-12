/** Runs inside the computer as its ordinary user. A subreaper owns even double-forked tools. */
export const computerProcessProgram = String.raw`
import ctypes, json, os, pathlib, signal, socket, subprocess, sys, threading, time

if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    raise RuntimeError('subreaper_unavailable')
config = json.loads(sys.stdin.buffer.readline(1024 * 1024))
# Abstract sockets cannot be unlinked while the previous helper still owns its children.
lease = None
if config.get('runKey'):
    lease = socket.socket(socket.AF_UNIX)
    lease.bind('\0native-bot-' + config['runKey'])
lock = threading.Lock()
stopping = threading.Event()
answers = {}
answer_lock = threading.Lock()
last_heartbeat = time.monotonic()

def send(value):
    with lock:
        try:
            sys.stdout.write(json.dumps(value, separators=(',', ':')) + '\n')
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            stopping.set()

def cleanup_children():
    # Freeze descendants before killing: they cannot escape by forking during teardown.
    # Double-forked children reparent to this subreaper, never the desktop's init.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        records = {}
        for entry in pathlib.Path('/proc').iterdir():
            if not entry.name.isdigit(): continue
            try:
                fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                records[int(entry.name)] = (int(fields[1]), fields[0], fields[19])
            except (OSError, ValueError, IndexError): pass
        family = {os.getpid()}
        while True:
            found = {pid for pid, row in records.items() if row[0] in family}
            if found.issubset(family): break
            family.update(found)
        live = [(pid, records[pid][2]) for pid in family if pid != os.getpid() and records[pid][1] != 'Z']
        for pid, identity in live:
            try:
                current = pathlib.Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()
                if current[19] == identity: os.kill(pid, signal.SIGSTOP)
            except (OSError, IndexError): pass
        if not live:
            while True:
                try:
                    if os.waitpid(-1, os.WNOHANG)[0] == 0: break
                except ChildProcessError: break
            return True
        # A second scan catches children forked before STOP took effect.
        time.sleep(0.02)
        for pid, identity in live:
            try:
                current = pathlib.Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()
                if current[19] == identity: os.kill(pid, signal.SIGKILL)
            except (OSError, IndexError): pass
        while True:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0: break
            except ChildProcessError: break
    return False

broker = socket.socket(socket.AF_UNIX)
broker.bind(config['socket'])
os.chmod(config['socket'], 0o600)
broker.listen(16)
broker.settimeout(0.2)

def handle_permission(connection):
    try:
        connection.settimeout(600)
        stream = connection.makefile('rb')
        raw = stream.readline(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024: return
        request = json.loads(raw)
        request_id = request['id']
        event = threading.Event()
        item = {'event': event, 'answer': {'behavior': 'deny'}}
        with answer_lock:
            if len(answers) >= 64 or request_id in answers: return
            answers[request_id] = item
        send({'type': 'request', 'request': request})
        while not event.wait(0.2):
            if stopping.is_set(): break
        connection.sendall((json.dumps({'id': request_id, 'answer': item['answer']}) + '\n').encode())
    except (OSError, ValueError, KeyError): pass
    finally:
        with answer_lock:
            if 'request_id' in locals(): answers.pop(request_id, None)
        connection.close()

def accept_permissions():
    while not stopping.is_set():
        try:
            connection, _ = broker.accept()
            threading.Thread(target=handle_permission, args=(connection,), daemon=True).start()
        except socket.timeout: pass
        except OSError: break

child = subprocess.Popen(config['command'], cwd=config['workspace'], env=config['env'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

def forward_output():
    while True:
        line = child.stdout.readline(2 * 1024 * 1024 + 1)
        if not line: return
        if len(line) > 2 * 1024 * 1024:
            stopping.set(); return
        try: decoded = line.decode('utf-8', errors='strict').rstrip('\n')
        except UnicodeError:
            stopping.set(); return
        send({'type': 'line', 'line': decoded})

def drain_errors():
    while child.stderr.read(8192): pass

def control():
    global last_heartbeat
    try:
        while not stopping.is_set():
            raw = sys.stdin.buffer.readline(1024 * 1024 + 1)
            if not raw or len(raw) > 1024 * 1024: break
            message = json.loads(raw)
            if message['type'] == 'input':
                child.stdin.write((json.dumps(message['frame']) + '\n').encode()); child.stdin.flush()
            elif message['type'] == 'answer':
                with answer_lock:
                    item = answers.get(message['id'])
                    if item:
                        item['answer'] = message['answer']; item['event'].set()
            elif message['type'] == 'heartbeat': last_heartbeat = time.monotonic()
            elif message['type'] == 'stop': break
    except (OSError, ValueError, KeyError): pass
    finally: stopping.set()

for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signum, lambda *_: stopping.set())
output_thread = threading.Thread(target=forward_output, daemon=True)
output_thread.start()
for target in (accept_permissions, drain_errors, control):
    threading.Thread(target=target, daemon=True).start()
send({'type': 'ready'})
code = None
while not stopping.wait(0.05):
    code = child.poll()
    if code is not None or time.monotonic() - last_heartbeat > 15: break
stopping.set()
broker.close()
clean = cleanup_children()
output_thread.join(timeout=1)
if lease: lease.close()
try: os.unlink(config['socket'])
except OSError: pass
# This acknowledgement means all descendants have exited, not just that stdin closed.
send({'type': 'exit', 'code': code, 'clean': clean})
sys.exit(0 if clean else 1)
`;
