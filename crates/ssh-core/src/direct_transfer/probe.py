# Fixed read-only direct-transfer probe. No file writes, transferred bodies,
# remote user configuration, passwords, private keys or remote stderr output.
import base64
import hashlib
import json
import ipaddress
import re
import shlex
import os
import shutil
import signal
import stat
import subprocess
import sys


def known_hosts_program(expected):
    # OpenSSH argv parsing, not a shell. The literal code has no double quotes
    # or backslashes, while the injected digest is validated base64 only.
    return (
        'import base64,hashlib,sys;'
        'reason,fingerprint,kind,key=sys.argv[1:];'
        "sys.exit(0) if reason=='ORDER' else None;"
        'raw=base64.b64decode(key,validate=True);'
        "actual='SHA256:'+base64.b64encode(hashlib.sha256(raw).digest()).decode().rstrip('=');"
        f"sys.exit(1) if actual!='{expected}' or fingerprint!=actual else None;"
        "sys.exit(1) if not(8<=len(raw)<=16384) or not kind or len(kind)>128 or any(not(c.isalnum() or c in '@._+-') for c in kind) else None;"
        "print('hspterm-direct-target '+kind+' '+key)"
    )


def ssh_arguments(endpoint, ssh, python):
    digest = endpoint['fingerprint']
    raw = base64.b64decode(digest[7:] + '=', validate=True)
    if len(raw) != 32 or digest != 'SHA256:' + base64.b64encode(raw).decode().rstrip('='):
        raise ValueError('invalid fingerprint')
    # Only this fixed script is quoted for OpenSSH's own argv parser. No endpoint
    # address, user or path is interpolated into KnownHostsCommand or a shell.
    program = known_hosts_program(digest)
    verifier = '"' + python + '" -I -S -c "' + program + '" %I %f %t %K'
    options = [
        'BatchMode=yes', 'NumberOfPasswordPrompts=0',
        'PasswordAuthentication=no', 'KbdInteractiveAuthentication=no',
        'PreferredAuthentications=publickey', 'PubkeyAuthentication=yes',
        'IdentityFile=none', 'CertificateFile=none', 'IdentitiesOnly=no',
        'IdentityAgent=SSH_AUTH_SOCK', 'PKCS11Provider=none',
        'SecurityKeyProvider=none', 'AddKeysToAgent=no',
        'UserKnownHostsFile=/dev/null', 'GlobalKnownHostsFile=/dev/null',
        'StrictHostKeyChecking=yes', 'VerifyHostKeyDNS=no', 'CheckHostIP=no',
        'HostKeyAlias=hspterm-direct-target', 'UpdateHostKeys=no',
        'KnownHostsCommand=' + verifier,
        'HostKeyAlgorithms=' + ({'ssh-rsa': 'rsa-sha2-512,rsa-sha2-256'}.get(endpoint['algorithm'], endpoint['algorithm'])),
        'ForwardAgent=no', 'ForwardX11=no', 'ClearAllForwardings=yes',
        'ControlMaster=no', 'ControlPath=none', 'PermitLocalCommand=no',
        'ProxyCommand=none', 'ProxyJump=none', 'ConnectionAttempts=1',
        'ConnectTimeout=5', 'ServerAliveInterval=5', 'ServerAliveCountMax=2',
        'LogLevel=QUIET', 'RequestTTY=no',
    ]
    argv = [ssh, '-F', '/dev/null', '-T']
    for option in options:
        argv.extend(['-o', option])
    target_check = ("import os,shutil,subprocess,sys;"
                    "r=shutil.which('rsync',path=os.defpath);"
                    "sys.exit(1) if not r or not os.path.isdir('/proc/self/fd') else None;"
                    "sys.exit(subprocess.call([r,'--protect-args','--version'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env={'PATH':os.defpath,'LC_ALL':'C'}))")
    command = '/usr/bin/python3 -I -S -c ' + shlex.quote(target_check)
    argv.extend(['-p', str(endpoint['port']), '-l', endpoint['username'],
                 '--', endpoint['address'], command])
    return argv


def run(argv, environment):
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               env=environment, start_new_session=True, close_fds=True)
    try:
        return process.wait(timeout=7)
    except subprocess.TimeoutExpired:
        # Own and reap the whole local SSH/helper process group, not just a
        # discarded timeout Future. No remote file mutation was requested.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            process.wait()
        raise


def probe(endpoint):
    if set(endpoint) != {'version', 'address', 'port', 'username', 'fingerprint', 'algorithm'} or endpoint['version'] != 1:
        return 'unsupported'
    address = endpoint['address']
    username = endpoint['username']
    if (not isinstance(address, str) or not address or len(address) > 253
            or not isinstance(username, str) or not username or len(username) > 1024
            or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in username)
            or type(endpoint['port']) is not int or not 1 <= endpoint['port'] <= 65535
            or endpoint['algorithm'] not in {'ssh-ed25519', 'ssh-rsa',
                'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521'}
            or not isinstance(endpoint['fingerprint'], str)
            or not re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', endpoint['fingerprint'])):
        return 'unsupported'
    try:
        ipaddress.ip_address(address)
    except ValueError:
        if address.startswith('-') or not re.fullmatch(r'[A-Za-z0-9._-]+', address):
            return 'unsupported'
    # Remote application/user PATH cannot select helper programs. No shell=True,
    # askpass, preloaded library or other inherited SSH/rsync options are used.
    ssh = shutil.which('ssh', path=os.defpath)
    rsync = shutil.which('rsync', path=os.defpath)
    python = shutil.which('python3', path=os.defpath)
    if not ssh or not rsync or not python or not os.path.isdir('/proc/self/fd'):
        return 'missing_tools'
    socket = os.environ.get('SSH_AUTH_SOCK', '')
    try:
        if not socket or not stat.S_ISSOCK(os.stat(socket).st_mode):
            return 'agent_unavailable'
    except OSError:
        return 'agent_unavailable'
    environment = {'PATH': os.defpath, 'LC_ALL': 'C', 'SSH_AUTH_SOCK': socket,
                   'SSH_ASKPASS_REQUIRE': 'never'}
    if run([rsync, '--protect-args', '--version'], environment) != 0:
        return 'unsupported'
    return 'available' if run(ssh_arguments(endpoint, ssh, python), environment) == 0 else 'authentication_failed'


def main():
    status = 'unsupported'
    try:
        if len(sys.argv) == 2 and len(sys.argv[1]) <= 8192:
            endpoint = json.loads(base64.b64decode(sys.argv[1], validate=True))
            status = probe(endpoint)
    except subprocess.TimeoutExpired:
        status = 'timeout'
    except (OSError, ValueError, TypeError, KeyError):
        status = 'unsupported'
    print(json.dumps({'version': 1, 'status': status}, separators=(',', ':')))


if __name__ == '__main__':
    main()
