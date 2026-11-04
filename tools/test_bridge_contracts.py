"""Source-audit regressions queued for the final unified test phase."""
import unittest
from bridge_contracts import audit, rust_signatures, dart_calls, rust_structs, dto_audit


class BridgeContractSourceTests(unittest.TestCase):
    def test_nested_rust_generic_arguments_optional_and_stream_sink(self):
        source = '''pub async fn watch_events(id: u32, sink: StreamSink<Result<Event, Error>>) -> Result<()> { Ok(()) }
pub fn enqueue_transfer(id: u32, paths: Vec<(String, u64)>, expected_generation: Option<u64>) -> Result<String> { todo!() }
impl Other { pub fn not_public_api() {} }'''
        signatures = rust_signatures(source)
        self.assertEqual(signatures['watchEvents'], ({'id'}, {'id'}))
        self.assertEqual(signatures['enqueueTransfer'], ({'id', 'paths', 'expectedGeneration'}, {'id', 'paths'}))
        self.assertNotIn('notPublicApi', signatures)

    def test_ternary_property_names_and_nested_values_are_not_parameter_labels(self):
        source = '''rust.enqueueTransfer(id: ready ? one.id : two.id, paths: [Pair(path: '/fixture')], expectedGeneration: null);'''
        self.assertEqual(list(dart_calls(source, {'rust'}))[0][:2],
                         ('enqueueTransfer', {'id', 'paths', 'expectedGeneration'}))

    def test_comments_raw_triple_and_nested_interpolation_strings_are_not_calls(self):
        source = """/* nested /* rust.fake() */ */
final ignored = r'''rust.fake()''';
final nested = '${state ? "${'rust.fake()'}" : 'other'}';
// rust.fake()
rust.real(id: 4);"""
        self.assertEqual([name for name, _, _ in dart_calls(source, {'rust'})], ['real'])

    def test_actual_imports_and_missing_or_unknown_fields_fail_without_generated_bindings(self):
        signatures = rust_signatures('pub fn actual(first: u32, extra: Option<u64>) {}')
        source = "import 'src/rust/api.dart' as rust;\nrust.actual(first: 1);\nrust.actual(wrong: 1);\nrust.unknown();"
        issues = list(audit(source, signatures))
        self.assertEqual(len(issues), 2)
        self.assertEqual(issues[0][0:2], (3, 'actual'))
        self.assertIn('wrong', issues[0][2])
        self.assertIn('first', issues[0][2])
        self.assertEqual(issues[1][1], 'unknown')

    def test_dto_fields_keep_nested_types_optional_fields_and_alias_scope(self):
        source = 'pub struct TaskView { pub task_id: String, pub active: Vec<(String, u64)>, pub generation: Option<u64> }'
        structs = dict(rust_structs(source))
        self.assertEqual(structs['TaskView'], ({'taskId', 'active', 'generation'}, {'taskId', 'active'}))
        dart = "import '../src/rust/transfers.dart' as jobs;\njobs.TaskView(taskId: 'fixture', active: [(one.id, 2)]);\njobs.TaskView(taskId: 'fixture', typo: true);\nforeign.TaskView();"
        issues = list(dto_audit(dart, structs))
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0][1], 'TaskView')
        self.assertIn('typo', issues[0][2])
        self.assertIn('active', issues[0][2])

    def test_dto_unaliased_calls_are_checked_only_with_real_rust_import(self):
        structs = dict(rust_structs('pub struct Input { pub rows: u32 }'))
        self.assertEqual(list(dto_audit('Input();', structs)), [])
        self.assertEqual(len(list(dto_audit("import 'package:hspterm/src/rust/api.dart'; Input();", structs))), 1)


if __name__ == '__main__':
    unittest.main()
