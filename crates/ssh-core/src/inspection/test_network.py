"""Deterministic procfs fixtures: never use real server credentials or traffic."""
import ast
from pathlib import Path
import unittest
from unittest.mock import patch

# The probe's CLI deliberately exits on any failure; load its definitions only.
namespace = {}
tree = ast.parse(Path(__file__).with_name('probe.py').read_text())
tree.body = [node for node in tree.body if not isinstance(node, ast.Try)]
exec(compile(tree, 'probe.py', 'exec'), namespace)


class NetworkTests(unittest.TestCase):
    def sample(self, routes, devices, indices=None, ipv6=b''):
        files = {'/proc/net/route': b'header\n' + routes,
                 '/proc/net/ipv6_route': ipv6,
                 '/proc/net/dev': b'header\nheader\n' + devices}
        for name, index in (indices or {'eth0': 2}).items():
            files['/sys/class/net/%s/ifindex' % name] = str(index).encode()
        with patch.dict(namespace, read=lambda path, limit=65536: files[path]):
            return namespace['network']()[:3]

    @staticmethod
    def dev(name, rx, tx):
        return ('%s: %d 0 0 0 0 0 0 0 %d 0 0 0 0 0 0 0\n' % (name, rx, tx)).encode()

    def test_bridge_veth_and_loopback_do_not_mirror_the_wire(self):
        rows = (self.dev('eth0', 1000, 40) + self.dev('docker0', 400, 800)
                + self.dev('veth12', 800, 400) + self.dev('lo', 9000, 9000))
        route = b'eth0 00000000 0100000A 0003 0 0 100 00000000\n'
        self.assertEqual(self.sample(route, rows), ('eth0:2', 1000, 40))

    def test_lowest_metric_scope_changes_with_recreated_device(self):
        route = (b'eth0 00000000 00000000 0001 0 0 100 00000000\n'
                 b'tun0 00000000 00000000 0001 0 0 10 00000000\n')
        rows = self.dev('eth0', 9000, 9000) + self.dev('tun0', 123, 456)
        self.assertEqual(self.sample(route, rows, {'tun0': 8}), ('tun0:8', 123, 456))
        self.assertEqual(self.sample(route, rows, {'tun0': 9}), ('tun0:9', 123, 456))

    def test_no_default_reports_no_trustworthy_scope_not_fake_total(self):
        self.assertEqual(self.sample(b'', self.dev('eth0', 10, 20)), ('', 0, 0))

    def test_ipv6_default_fallback(self):
        route = b'0'*32 + b' 00 ' + b'0'*32 + b' 00 ' + b'0'*32 + b' 00000064 0 0 00000001 eth0\n'
        self.assertEqual(self.sample(b'', self.dev('eth0', 9, 7), ipv6=route), ('eth0:2', 9, 7))


if __name__ == '__main__':
    unittest.main()
